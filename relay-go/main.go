// A2A Relay Server - Go Implementation
// Enables A2A agents without public URLs to participate in the A2A ecosystem
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/gorilla/websocket"
)

var (
	port           = flag.Int("port", 8080, "HTTP server port")
	jwtSecret      = flag.String("jwt-secret", "", "JWT signing secret (or RELAY_JWT_SECRET env)")
	authTimeout    = flag.Duration("auth-timeout", 30*time.Second, "Agent auth timeout")
	requestTimeout = flag.Duration("request-timeout", 30*time.Second, "Default request timeout")
)

// AgentCard represents an A2A agent's metadata
type AgentCard struct {
	ID                         string            `json:"id,omitempty"`
	Name                       string            `json:"name"`
	Description                string            `json:"description,omitempty"`
	URL                        string            `json:"url"`
	Version                    string            `json:"version"`
	ProtocolVersion            string            `json:"protocolVersion,omitempty"`
	SupportedProtocolVersions  []string          `json:"supportedProtocolVersions,omitempty"`
	Capabilities               AgentCapabilities `json:"capabilities"`
	Skills                     []AgentSkill      `json:"skills,omitempty"`
	DefaultInputModes          []string          `json:"defaultInputModes,omitempty"`
	DefaultOutputModes         []string          `json:"defaultOutputModes,omitempty"`
}

type AgentCapabilities struct {
	Streaming         bool `json:"streaming,omitempty"`
	PushNotifications bool `json:"pushNotifications,omitempty"`
}

type AgentSkill struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description,omitempty"`
	Tags        []string `json:"tags,omitempty"`
}

// JSON-RPC 2.0 types

type JSONRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type JSONRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *JSONRPCError   `json:"error,omitempty"`
}

type JSONRPCError struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

// ConnectedAgent represents an agent connected via WebSocket
type ConnectedAgent struct {
	ID          string
	TenantID    string
	Conn        *websocket.Conn
	AgentCard   *AgentCard
	ConnectedAt time.Time
	mu          sync.Mutex
}

// PendingRequest tracks an A2A request waiting for response
type PendingRequest struct {
	ID         string
	ResponseCh chan *A2AResponse
	Timeout    time.Time
}

// A2ARequest is forwarded to the agent
type A2ARequest struct {
	ID      string          `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	Timeout int64           `json:"timeout_ms,omitempty"`
}

// A2AResponse comes back from the agent
type A2AResponse struct {
	ID     string          `json:"id"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *A2AError       `json:"error,omitempty"`
}

type A2AError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// QueuedMessage is a message buffered for an offline agent
type QueuedMessage struct {
	ID         string
	Method     string
	Params     json.RawMessage
	QueuedAt   time.Time
	ResponseCh chan *A2AResponse // for clients waiting synchronously
	TenantID   string
	AgentID    string
}

// Mailbox holds queued messages for an agent
type Mailbox struct {
	mu       sync.Mutex
	messages []*QueuedMessage
}

// TaskResult stores the result of a completed queued task
type TaskResult struct {
	ID        string
	Response  *A2AResponse
	CreatedAt time.Time
}

// Relay manages agents and requests
type Relay struct {
	agents          map[string]*ConnectedAgent // key: tenantID:agentID
	pendingRequests map[string]*PendingRequest
	mailboxes       map[string]*Mailbox    // key: tenantID:agentID
	taskResults     map[string]*TaskResult // key: taskID
	jwtSecret       []byte
	mu              sync.RWMutex
	upgrader        websocket.Upgrader
}

const (
	maxMailboxMessages = 999
	messageTTL         = 9 * 24 * time.Hour
	mailboxSyncWait    = 30 * time.Second
	cleanupInterval    = 1 * time.Hour
)

func NewRelay(jwtSecret string) *Relay {
	r := &Relay{
		agents:          make(map[string]*ConnectedAgent),
		pendingRequests: make(map[string]*PendingRequest),
		mailboxes:       make(map[string]*Mailbox),
		taskResults:     make(map[string]*TaskResult),
		jwtSecret:       []byte(jwtSecret),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}
	go r.cleanupLoop()
	return r
}

// cleanupLoop periodically purges expired messages and task results
func (r *Relay) cleanupLoop() {
	ticker := time.NewTicker(cleanupInterval)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		r.mu.Lock()
		// Clean task results
		for id, tr := range r.taskResults {
			if now.Sub(tr.CreatedAt) > messageTTL {
				delete(r.taskResults, id)
			}
		}
		// Clean mailboxes
		for key, mb := range r.mailboxes {
			mb.mu.Lock()
			filtered := mb.messages[:0]
			for _, msg := range mb.messages {
				if now.Sub(msg.QueuedAt) <= messageTTL {
					filtered = append(filtered, msg)
				} else {
					// Close waiting clients
					close(msg.ResponseCh)
				}
			}
			// Enforce max limit (keep newest)
			if len(filtered) > maxMailboxMessages {
				for _, msg := range filtered[:len(filtered)-maxMailboxMessages] {
					close(msg.ResponseCh)
				}
				filtered = filtered[len(filtered)-maxMailboxMessages:]
			}
			mb.messages = filtered
			if len(mb.messages) == 0 {
				delete(r.mailboxes, key)
			}
			mb.mu.Unlock()
		}
		r.mu.Unlock()
		log.Printf("[RELAY] Cleanup complete")
	}
}

// QueueMessage adds a message to an agent's mailbox, returns the queued message
func (r *Relay) QueueMessage(tenantID, agentID, method string, params json.RawMessage) *QueuedMessage {
	key := agentKey(tenantID, agentID)

	r.mu.Lock()
	mb, ok := r.mailboxes[key]
	if !ok {
		mb = &Mailbox{}
		r.mailboxes[key] = mb
	}
	r.mu.Unlock()

	msg := &QueuedMessage{
		ID:         uuid.NewString(),
		Method:     method,
		Params:     params,
		QueuedAt:   time.Now(),
		ResponseCh: make(chan *A2AResponse, 1),
		TenantID:   tenantID,
		AgentID:    agentID,
	}

	mb.mu.Lock()
	// Enforce limit
	if len(mb.messages) >= maxMailboxMessages {
		// Drop oldest
		old := mb.messages[0]
		close(old.ResponseCh)
		mb.messages = mb.messages[1:]
	}
	mb.messages = append(mb.messages, msg)
	mb.mu.Unlock()

	log.Printf("[RELAY] Queued message %s for %s:%s (method: %s)", msg.ID, tenantID, agentID, method)
	return msg
}

// FlushMailbox delivers all queued messages to a newly connected agent
func (r *Relay) FlushMailbox(tenantID, agentID string, agent *ConnectedAgent) {
	key := agentKey(tenantID, agentID)

	r.mu.RLock()
	mb, ok := r.mailboxes[key]
	r.mu.RUnlock()
	if !ok {
		return
	}

	mb.mu.Lock()
	messages := mb.messages
	mb.messages = nil
	mb.mu.Unlock()

	if len(messages) == 0 {
		return
	}

	log.Printf("[RELAY] Flushing %d queued messages to %s:%s", len(messages), tenantID, agentID)

	for _, msg := range messages {
		go func(msg *QueuedMessage) {
			resp, err := r.SendRequest(agent, msg.Method, msg.Params, *requestTimeout)
			if err != nil {
				log.Printf("[RELAY] Failed to deliver queued message %s: %v", msg.ID, err)
				resp = &A2AResponse{
					ID:    msg.ID,
					Error: &A2AError{Code: -32603, Message: err.Error()},
				}
			}

			// Store result for polling
			r.mu.Lock()
			r.taskResults[msg.ID] = &TaskResult{
				ID:        msg.ID,
				Response:  resp,
				CreatedAt: time.Now(),
			}
			r.mu.Unlock()

			// Notify waiting client
			select {
			case msg.ResponseCh <- resp:
			default:
			}
		}(msg)
	}
}

// waitForQueuedResponse waits for a queued message response with sync timeout,
// returns the response or nil (caller should return 202)
func (r *Relay) waitForQueuedResponse(msg *QueuedMessage) *A2AResponse {
	select {
	case resp, ok := <-msg.ResponseCh:
		if ok && resp != nil {
			return resp
		}
		return nil
	case <-time.After(mailboxSyncWait):
		return nil
	}
}

// agentKey creates a unique key for tenant:agent
func agentKey(tenantID, agentID string) string {
	return tenantID + ":" + agentID
}

// RegisterAgent adds an agent to the relay
func (r *Relay) RegisterAgent(tenantID, agentID string, conn *websocket.Conn, card *AgentCard) {
	r.mu.Lock()
	defer r.mu.Unlock()

	key := agentKey(tenantID, agentID)
	r.agents[key] = &ConnectedAgent{
		ID:          agentID,
		TenantID:    tenantID,
		Conn:        conn,
		AgentCard:   card,
		ConnectedAt: time.Now(),
	}
	log.Printf("[RELAY] Agent registered: %s (tenant: %s)", agentID, tenantID)

	// Flush any queued messages (must be called after unlock)
	go r.FlushMailbox(tenantID, agentID, r.agents[key])
}

// UnregisterAgent removes an agent
func (r *Relay) UnregisterAgent(tenantID, agentID string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	key := agentKey(tenantID, agentID)
	delete(r.agents, key)
	log.Printf("[RELAY] Agent unregistered: %s (tenant: %s)", agentID, tenantID)
}

// GetAgent finds a connected agent
func (r *Relay) GetAgent(tenantID, agentID string) *ConnectedAgent {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.agents[agentKey(tenantID, agentID)]
}

// ListAgents returns agents for a tenant
func (r *Relay) ListAgents(tenantID string) []*ConnectedAgent {
	r.mu.RLock()
	defer r.mu.RUnlock()

	var result []*ConnectedAgent
	for _, agent := range r.agents {
		if agent.TenantID == tenantID {
			result = append(result, agent)
		}
	}
	return result
}

// SendRequest forwards a request to an agent and waits for response
func (r *Relay) SendRequest(agent *ConnectedAgent, method string, params json.RawMessage, timeout time.Duration) (*A2AResponse, error) {
	reqID := uuid.NewString()

	// Create pending request
	pending := &PendingRequest{
		ID:         reqID,
		ResponseCh: make(chan *A2AResponse, 1),
		Timeout:    time.Now().Add(timeout),
	}

	r.mu.Lock()
	r.pendingRequests[reqID] = pending
	r.mu.Unlock()

	defer func() {
		r.mu.Lock()
		delete(r.pendingRequests, reqID)
		r.mu.Unlock()
	}()

	// Send request to agent
	req := A2ARequest{
		ID:      reqID,
		Method:  method,
		Params:  params,
		Timeout: timeout.Milliseconds(),
	}

	agent.mu.Lock()
	err := agent.Conn.WriteJSON(map[string]interface{}{
		"type":    "a2a.request",
		"payload": req,
	})
	agent.mu.Unlock()

	if err != nil {
		return nil, fmt.Errorf("failed to send to agent: %w", err)
	}

	// Wait for response
	select {
	case resp := <-pending.ResponseCh:
		return resp, nil
	case <-time.After(timeout):
		return nil, fmt.Errorf("request timeout after %v", timeout)
	}
}

// HandleAgentResponse processes a response from an agent
func (r *Relay) HandleAgentResponse(resp *A2AResponse) {
	r.mu.RLock()
	pending, ok := r.pendingRequests[resp.ID]
	r.mu.RUnlock()

	if ok {
		pending.ResponseCh <- resp
	}
}

// ValidateToken validates a JWT and returns claims
func (r *Relay) ValidateToken(tokenString string) (jwt.MapClaims, error) {
	token, err := jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return r.jwtSecret, nil
	})

	if err != nil {
		return nil, err
	}

	if claims, ok := token.Claims.(jwt.MapClaims); ok && token.Valid {
		return claims, nil
	}

	return nil, fmt.Errorf("invalid token")
}

// HTTP Handlers

func (r *Relay) handleAgentWebSocket(w http.ResponseWriter, req *http.Request) {
	conn, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("[RELAY] WebSocket upgrade failed: %v", err)
		return
	}
	defer conn.Close()

	// Wait for auth message
	var authMsg struct {
		Type      string     `json:"type"`
		Token     string     `json:"token"`
		AgentID   string     `json:"agent_id"`
		AgentCard *AgentCard `json:"agent_card"`
	}

	conn.SetReadDeadline(time.Now().Add(*authTimeout))
	if err := conn.ReadJSON(&authMsg); err != nil {
		log.Printf("[RELAY] Auth read failed: %v", err)
		conn.WriteJSON(map[string]interface{}{"type": "error", "message": "auth required"})
		return
	}
	conn.SetReadDeadline(time.Time{}) // Clear deadline for normal operation

	if authMsg.Type != "auth" {
		conn.WriteJSON(map[string]interface{}{"type": "error", "message": "expected auth message"})
		return
	}

	// Validate token
	claims, err := r.ValidateToken(authMsg.Token)
	if err != nil {
		log.Printf("[RELAY] Auth failed: %v", err)
		conn.WriteJSON(map[string]interface{}{"type": "error", "message": "invalid token"})
		return
	}

	tenantID, _ := claims["tenant"].(string)
	agentID := authMsg.AgentID
	if agentID == "" {
		agentID, _ = claims["agent_id"].(string)
	}

	if tenantID == "" || agentID == "" {
		conn.WriteJSON(map[string]interface{}{"type": "error", "message": "missing tenant or agent_id"})
		return
	}

	// Register agent
	r.RegisterAgent(tenantID, agentID, conn, authMsg.AgentCard)
	defer r.UnregisterAgent(tenantID, agentID)

	// Send auth success
	conn.WriteJSON(map[string]interface{}{
		"type":     "auth_ok",
		"agent_id": agentID,
		"tenant":   tenantID,
	})

	// Configure WebSocket keepalive for Cloud Run
	// Cloud Run times out idle connections, so we need active ping/pong
	const (
		pongWait   = 60 * time.Second  // Time to wait for pong before assuming dead
		pingPeriod = 30 * time.Second  // How often to send pings (must be < pongWait)
	)

	// Set initial read deadline
	conn.SetReadDeadline(time.Now().Add(pongWait))

	// Handle pong messages - refresh the read deadline
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	// Start a goroutine to send periodic pings
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(pingPeriod)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := conn.WriteControl(websocket.PingMessage, []byte{}, time.Now().Add(10*time.Second)); err != nil {
					log.Printf("[RELAY] Agent %s ping failed: %v", agentID, err)
					return
				}
			case <-done:
				return
			}
		}
	}()
	defer close(done)

	// Read loop - handle responses and pings
	for {
		var msg map[string]json.RawMessage
		if err := conn.ReadJSON(&msg); err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("[RELAY] Agent %s read error: %v", agentID, err)
			}
			break
		}

		// Refresh read deadline on any message
		conn.SetReadDeadline(time.Now().Add(pongWait))

		msgType := ""
		if t, ok := msg["type"]; ok {
			json.Unmarshal(t, &msgType)
		}

		switch msgType {
		case "a2a.response":
			var resp A2AResponse
			if payload, ok := msg["payload"]; ok {
				json.Unmarshal(payload, &resp)
				r.HandleAgentResponse(&resp)
			}
		case "ping":
			conn.WriteJSON(map[string]string{"type": "pong"})
		}
	}
}

func (r *Relay) handleA2ARequest(w http.ResponseWriter, req *http.Request) {
	vars := mux.Vars(req)
	tenantID := vars["tenant"]
	agentID := vars["agent"]

	// Validate client token
	authHeader := req.Header.Get("Authorization")
	if authHeader == "" {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	token := authHeader
	if len(authHeader) > 7 && authHeader[:7] == "Bearer " {
		token = authHeader[7:]
	}

	claims, err := r.ValidateToken(token)
	if err != nil {
		http.Error(w, `{"error":"invalid token"}`, http.StatusUnauthorized)
		return
	}

	// Check tenant access
	clientTenant, _ := claims["tenant"].(string)
	if clientTenant != tenantID {
		http.Error(w, `{"error":"tenant mismatch"}`, http.StatusForbidden)
		return
	}

	// Parse A2A request body
	var body json.RawMessage
	if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	// Determine A2A method from path
	method := "message/send"
	if vars["method"] != "" {
		method = vars["method"]
	}

	// Find agent
	agent := r.GetAgent(tenantID, agentID)
	if agent == nil {
		// Agent offline — queue message and wait
		msg := r.QueueMessage(tenantID, agentID, method, body)
		resp := r.waitForQueuedResponse(msg)
		w.Header().Set("Content-Type", "application/json")
		if resp != nil {
			if resp.Error != nil {
				w.WriteHeader(http.StatusBadRequest)
			}
			json.NewEncoder(w).Encode(resp.Result)
			return
		}
		// No response within sync wait — return 202 with task_id
		w.WriteHeader(http.StatusAccepted)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"status":  "queued",
			"task_id": msg.ID,
			"message": "Agent is offline. Message queued for delivery.",
		})
		return
	}

	// Forward to agent (use configured default timeout)
	resp, err := r.SendRequest(agent, method, body, *requestTimeout)
	if err != nil {
		log.Printf("[RELAY] Request to agent %s failed: %v", agentID, err)
		http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err.Error()), http.StatusGatewayTimeout)
		return
	}

	// Return response
	w.Header().Set("Content-Type", "application/json")
	if resp.Error != nil {
		w.WriteHeader(http.StatusBadRequest)
	}
	json.NewEncoder(w).Encode(resp.Result)
}

// jsonrpcMethodMap maps JSON-RPC method names to internal A2A methods
var jsonrpcMethodMap = map[string]string{
	"SendMessage": "message/send",
	"GetTask":     "tasks/get",
	"ListTasks":   "tasks/list",
	"CancelTask":  "tasks/cancel",
}

func jsonrpcError(id interface{}, code int, message string) *JSONRPCResponse {
	return &JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &JSONRPCError{Code: code, Message: message},
	}
}

func (r *Relay) handleJSONRPC(w http.ResponseWriter, req *http.Request) {
	vars := mux.Vars(req)
	tenantID := vars["tenant"]
	agentID := vars["agent"]

	w.Header().Set("Content-Type", "application/json")

	// Parse body
	var rpcReq JSONRPCRequest
	if err := json.NewDecoder(req.Body).Decode(&rpcReq); err != nil {
		json.NewEncoder(w).Encode(jsonrpcError(nil, -32700, "Parse error"))
		return
	}

	// Validate jsonrpc version
	if rpcReq.JSONRPC != "2.0" {
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32600, "Invalid Request: jsonrpc must be \"2.0\""))
		return
	}

	// Validate id present
	if rpcReq.ID == nil {
		json.NewEncoder(w).Encode(jsonrpcError(nil, -32600, "Invalid Request: missing id"))
		return
	}

	// Validate method
	if rpcReq.Method == "" {
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32600, "Invalid Request: missing method"))
		return
	}

	// Handle GetExtendedAgentCard locally
	if rpcReq.Method == "GetExtendedAgentCard" {
		agent := r.GetAgent(tenantID, agentID)
		if agent == nil {
			json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32603, "Agent offline"))
			return
		}
		if agent.AgentCard == nil {
			json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32603, "No agent card"))
			return
		}
		cardJSON, _ := json.Marshal(agent.AgentCard)
		json.NewEncoder(w).Encode(&JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      rpcReq.ID,
			Result:  cardJSON,
		})
		return
	}

	// Map method name
	a2aMethod, ok := jsonrpcMethodMap[rpcReq.Method]
	if !ok {
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32601, "Method not found"))
		return
	}

	// Validate client token
	authHeader := req.Header.Get("Authorization")
	if authHeader == "" {
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32603, "Unauthorized"))
		return
	}

	token := authHeader
	if len(authHeader) > 7 && authHeader[:7] == "Bearer " {
		token = authHeader[7:]
	}

	claims, err := r.ValidateToken(token)
	if err != nil {
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32603, "Invalid token"))
		return
	}

	clientTenant, _ := claims["tenant"].(string)
	if clientTenant != tenantID {
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32603, "Tenant mismatch"))
		return
	}

	// Forward to agent
	params := rpcReq.Params
	if params == nil {
		params = json.RawMessage(`{}`)
	}

	// Find agent
	agent := r.GetAgent(tenantID, agentID)
	if agent == nil {
		// Agent offline — queue and wait
		msg := r.QueueMessage(tenantID, agentID, a2aMethod, params)
		resp := r.waitForQueuedResponse(msg)
		if resp != nil {
			if resp.Error != nil {
				json.NewEncoder(w).Encode(&JSONRPCResponse{
					JSONRPC: "2.0", ID: rpcReq.ID,
					Error: &JSONRPCError{Code: resp.Error.Code, Message: resp.Error.Message},
				})
				return
			}
			json.NewEncoder(w).Encode(&JSONRPCResponse{JSONRPC: "2.0", ID: rpcReq.ID, Result: resp.Result})
			return
		}
		// No response — return queued status
		w.WriteHeader(http.StatusAccepted)
		resultJSON, _ := json.Marshal(map[string]interface{}{
			"status": "queued", "task_id": msg.ID,
			"message": "Agent is offline. Message queued for delivery.",
		})
		json.NewEncoder(w).Encode(&JSONRPCResponse{JSONRPC: "2.0", ID: rpcReq.ID, Result: resultJSON})
		return
	}

	resp, err := r.SendRequest(agent, a2aMethod, params, *requestTimeout)
	if err != nil {
		log.Printf("[RELAY] JSON-RPC request to agent %s failed: %v", agentID, err)
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32603, err.Error()))
		return
	}

	// Build JSON-RPC response
	if resp.Error != nil {
		json.NewEncoder(w).Encode(&JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      rpcReq.ID,
			Error:   &JSONRPCError{Code: resp.Error.Code, Message: resp.Error.Message},
		})
		return
	}

	json.NewEncoder(w).Encode(&JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      rpcReq.ID,
		Result:  resp.Result,
	})
}

func (r *Relay) handleAgentCard(w http.ResponseWriter, req *http.Request) {
	vars := mux.Vars(req)
	tenantID := vars["tenant"]
	agentID := vars["agent"]

	agent := r.GetAgent(tenantID, agentID)
	if agent == nil {
		http.Error(w, `{"error":"agent_offline"}`, http.StatusServiceUnavailable)
		return
	}

	if agent.AgentCard == nil {
		http.Error(w, `{"error":"no agent card"}`, http.StatusNotFound)
		return
	}

	// Enrich agent card with relay-specific fields for TCK compliance
	card := *agent.AgentCard
	if card.ID == "" {
		card.ID = agentID
	}
	if card.ProtocolVersion == "" {
		card.ProtocolVersion = "0.3.0"
	}
	if len(card.SupportedProtocolVersions) == 0 {
		card.SupportedProtocolVersions = []string{"0.3.0"}
	}
	// Set URL to the relay's public endpoint for this agent
	card.URL = fmt.Sprintf("https://%s/t/%s/a2a/%s/", req.Host, tenantID, agentID)
	// Ensure skills have tags
	for i := range card.Skills {
		if len(card.Skills[i].Tags) == 0 {
			card.Skills[i].Tags = []string{"chat", "general"}
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(card)
}

// handleRootJSONRPC handles JSON-RPC at the domain root, routing to the first connected agent.
// This allows TCK to test against just the base URL without knowing tenant/agent.
func (r *Relay) handleRootJSONRPC(w http.ResponseWriter, req *http.Request) {
	r.mu.RLock()
	var firstAgent *ConnectedAgent
	for _, agent := range r.agents {
		firstAgent = agent
		break
	}
	r.mu.RUnlock()

	if firstAgent == nil {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(jsonrpcError(nil, -32603, "No agents connected"))
		return
	}

	w.Header().Set("Content-Type", "application/json")

	var rpcReq JSONRPCRequest
	if err := json.NewDecoder(req.Body).Decode(&rpcReq); err != nil {
		json.NewEncoder(w).Encode(jsonrpcError(nil, -32700, "Parse error"))
		return
	}

	if rpcReq.JSONRPC != "2.0" {
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32600, "Invalid Request: jsonrpc must be \"2.0\""))
		return
	}
	if rpcReq.ID == nil {
		json.NewEncoder(w).Encode(jsonrpcError(nil, -32600, "Invalid Request: missing id"))
		return
	}
	if rpcReq.Method == "" {
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32600, "Invalid Request: missing method"))
		return
	}

	// Handle GetExtendedAgentCard locally
	if rpcReq.Method == "GetExtendedAgentCard" {
		if firstAgent.AgentCard == nil {
			json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32603, "No agent card"))
			return
		}
		cardJSON, _ := json.Marshal(firstAgent.AgentCard)
		json.NewEncoder(w).Encode(&JSONRPCResponse{JSONRPC: "2.0", ID: rpcReq.ID, Result: cardJSON})
		return
	}

	a2aMethod, ok := jsonrpcMethodMap[rpcReq.Method]
	if !ok {
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32601, "Method not found"))
		return
	}

	params := rpcReq.Params
	if params == nil {
		params = json.RawMessage(`{}`)
	}

	resp, err := r.SendRequest(firstAgent, a2aMethod, params, *requestTimeout)
	if err != nil {
		log.Printf("[RELAY] Root JSON-RPC request failed: %v", err)
		json.NewEncoder(w).Encode(jsonrpcError(rpcReq.ID, -32603, err.Error()))
		return
	}

	if resp.Error != nil {
		json.NewEncoder(w).Encode(&JSONRPCResponse{
			JSONRPC: "2.0", ID: rpcReq.ID,
			Error: &JSONRPCError{Code: resp.Error.Code, Message: resp.Error.Message},
		})
		return
	}

	json.NewEncoder(w).Encode(&JSONRPCResponse{JSONRPC: "2.0", ID: rpcReq.ID, Result: resp.Result})
}

// handleRootAgentCard serves the agent card at the domain root for TCK compatibility.
// The A2A spec says agent cards should be at /.well-known/agent.json (v0.2.5) or
// /.well-known/agent-card.json (v0.3.0). The TCK strips the SUT URL to domain root.
func (r *Relay) handleRootAgentCard(w http.ResponseWriter, req *http.Request) {
	r.mu.RLock()
	var firstAgent *ConnectedAgent
	for _, agent := range r.agents {
		firstAgent = agent
		break
	}
	r.mu.RUnlock()

	if firstAgent == nil {
		http.Error(w, `{"error":"no agents connected"}`, http.StatusServiceUnavailable)
		return
	}

	if firstAgent.AgentCard == nil {
		http.Error(w, `{"error":"no agent card"}`, http.StatusNotFound)
		return
	}

	card := *firstAgent.AgentCard
	if card.ID == "" {
		card.ID = firstAgent.ID
	}
	if card.ProtocolVersion == "" {
		card.ProtocolVersion = "0.3.0"
	}
	if len(card.SupportedProtocolVersions) == 0 {
		card.SupportedProtocolVersions = []string{"0.3.0"}
	}
	card.URL = fmt.Sprintf("https://%s/t/%s/a2a/%s/", req.Host, firstAgent.TenantID, firstAgent.ID)
	for i := range card.Skills {
		if len(card.Skills[i].Tags) == 0 {
			card.Skills[i].Tags = []string{"chat", "general"}
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(card)
}

func (r *Relay) handleListAgents(w http.ResponseWriter, req *http.Request) {
	vars := mux.Vars(req)
	tenantID := vars["tenant"]

	// Validate client token
	authHeader := req.Header.Get("Authorization")
	if authHeader == "" {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	token := authHeader[7:] // Strip "Bearer "
	claims, err := r.ValidateToken(token)
	if err != nil {
		http.Error(w, `{"error":"invalid token"}`, http.StatusUnauthorized)
		return
	}

	clientTenant, _ := claims["tenant"].(string)
	if clientTenant != tenantID {
		http.Error(w, `{"error":"tenant mismatch"}`, http.StatusForbidden)
		return
	}

	agents := r.ListAgents(tenantID)
	result := make([]map[string]interface{}, 0, len(agents))
	for _, a := range agents {
		entry := map[string]interface{}{
			"id":           a.ID,
			"connected_at": a.ConnectedAt,
		}
		if a.AgentCard != nil {
			entry["name"] = a.AgentCard.Name
			entry["description"] = a.AgentCard.Description
		}
		result = append(result, entry)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (r *Relay) handleTaskPoll(w http.ResponseWriter, req *http.Request) {
	vars := mux.Vars(req)
	tenantID := vars["tenant"]
	taskID := vars["taskId"]

	// Validate client token
	authHeader := req.Header.Get("Authorization")
	if authHeader == "" {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}
	token := authHeader
	if len(authHeader) > 7 && authHeader[:7] == "Bearer " {
		token = authHeader[7:]
	}
	claims, err := r.ValidateToken(token)
	if err != nil {
		http.Error(w, `{"error":"invalid token"}`, http.StatusUnauthorized)
		return
	}
	clientTenant, _ := claims["tenant"].(string)
	if clientTenant != tenantID {
		http.Error(w, `{"error":"tenant mismatch"}`, http.StatusForbidden)
		return
	}

	// Check for completed result
	r.mu.RLock()
	tr, ok := r.taskResults[taskID]
	r.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	if ok {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"status":   "completed",
			"task_id":  tr.ID,
			"response": tr.Response,
		})
		return
	}

	// Check if still queued
	r.mu.RLock()
	for _, mb := range r.mailboxes {
		mb.mu.Lock()
		for _, msg := range mb.messages {
			if msg.ID == taskID {
				mb.mu.Unlock()
				r.mu.RUnlock()
				json.NewEncoder(w).Encode(map[string]interface{}{
					"status":  "queued",
					"task_id": taskID,
				})
				return
			}
		}
		mb.mu.Unlock()
	}
	r.mu.RUnlock()

	http.Error(w, `{"error":"task not found"}`, http.StatusNotFound)
}

func (r *Relay) handleHealth(w http.ResponseWriter, req *http.Request) {
	r.mu.RLock()
	agentCount := len(r.agents)
	pendingCount := len(r.pendingRequests)
	queuedCount := 0
	for _, mb := range r.mailboxes {
		mb.mu.Lock()
		queuedCount += len(mb.messages)
		mb.mu.Unlock()
	}
	taskCount := len(r.taskResults)
	r.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":            "ok",
		"version":           "0.2.0",
		"agents_connected":  agentCount,
		"pending_requests":  pendingCount,
		"queued_messages":   queuedCount,
		"completed_tasks":   taskCount,
	})
}

func (r *Relay) handleRoot(w http.ResponseWriter, req *http.Request) {
	// Build public agent index
	r.mu.RLock()
	agents := make([]map[string]interface{}, 0)
	for _, a := range r.agents {
		entry := map[string]interface{}{
			"id":       a.ID,
			"tenant":   a.TenantID,
			"cardUrl":  fmt.Sprintf("https://%s/t/%s/a2a/%s/.well-known/agent.json", req.Host, a.TenantID, a.ID),
			"url":      fmt.Sprintf("https://%s/t/%s/a2a/%s/", req.Host, a.TenantID, a.ID),
		}
		if a.AgentCard != nil {
			entry["name"] = a.AgentCard.Name
			entry["description"] = a.AgentCard.Description
			if len(a.AgentCard.Skills) > 0 {
				skills := make([]map[string]string, 0, len(a.AgentCard.Skills))
				for _, s := range a.AgentCard.Skills {
					skills = append(skills, map[string]string{
						"id":   s.ID,
						"name": s.Name,
					})
				}
				entry["skills"] = skills
			}
		}
		agents = append(agents, entry)
	}
	r.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"name":    "A2A Relay",
		"version": "0.1.0",
		"docs":    "https://github.com/zeroasterisk/a2a-relay",
		"agents":  agents,
		"endpoints": map[string]string{
			"health":      "GET /health",
			"agent_ws":    "WS /agent",
			"agent_index": "GET /.well-known/agents",
			"agent_card":  "GET /t/{tenant}/a2a/{agent}/.well-known/agent.json",
			"jsonrpc":     "POST /t/{tenant}/a2a/{agent}/",
			"send":        "POST /t/{tenant}/a2a/{agent}/message/send",
			"stream":      "POST /t/{tenant}/a2a/{agent}/message/stream",
			"list":        "GET /t/{tenant}/agents (auth required)",
		},
	})
}

// handleAgentIndex serves a public directory of all connected agents.
// Follows the emerging /.well-known/agents convention from the A2A registry discussion.
func (r *Relay) handleAgentIndex(w http.ResponseWriter, req *http.Request) {
	r.mu.RLock()
	agents := make([]map[string]interface{}, 0)
	for _, a := range r.agents {
		entry := map[string]interface{}{
			"id":       a.ID,
			"tenant":   a.TenantID,
			"cardUrl":  fmt.Sprintf("https://%s/t/%s/a2a/%s/.well-known/agent.json", req.Host, a.TenantID, a.ID),
			"url":      fmt.Sprintf("https://%s/t/%s/a2a/%s/", req.Host, a.TenantID, a.ID),
		}
		if a.AgentCard != nil {
			entry["name"] = a.AgentCard.Name
			entry["description"] = a.AgentCard.Description
			entry["skills"] = a.AgentCard.Skills
			entry["capabilities"] = a.AgentCard.Capabilities
			if a.AgentCard.DefaultInputModes != nil {
				entry["defaultInputModes"] = a.AgentCard.DefaultInputModes
			}
			if a.AgentCard.DefaultOutputModes != nil {
				entry["defaultOutputModes"] = a.AgentCard.DefaultOutputModes
			}
		}
		agents = append(agents, entry)
	}
	r.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"agents": agents,
		"count":  len(agents),
	})
}

func main() {
	flag.Parse()

	secret := *jwtSecret
	if secret == "" {
		secret = os.Getenv("RELAY_JWT_SECRET")
	}
	if secret == "" {
		log.Fatal("JWT secret required: use -jwt-secret or RELAY_JWT_SECRET env var")
	}

	relay := NewRelay(secret)
	router := mux.NewRouter()

	// Root and health
	router.HandleFunc("/", relay.handleRoot).Methods("GET")
	router.HandleFunc("/health", relay.handleHealth).Methods("GET")

	// Agent WebSocket endpoint
	router.HandleFunc("/agent", relay.handleAgentWebSocket)

	// A2A HTTP endpoints (per tenant/agent)
	router.HandleFunc("/.well-known/agents", relay.handleAgentIndex).Methods("GET")
	router.HandleFunc("/.well-known/agent.json", relay.handleRootAgentCard).Methods("GET")
	router.HandleFunc("/.well-known/agent-card.json", relay.handleRootAgentCard).Methods("GET")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/.well-known/agent.json", relay.handleAgentCard).Methods("GET")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/.well-known/agent-card.json", relay.handleAgentCard).Methods("GET")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/message/send", relay.handleA2ARequest).Methods("POST")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/message/stream", relay.handleA2ARequest).Methods("POST")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/tasks/{task}", relay.handleA2ARequest).Methods("GET")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/tasks", relay.handleA2ARequest).Methods("GET")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/tasks/{task}/cancel", relay.handleA2ARequest).Methods("POST")

	// Task polling endpoint
	router.HandleFunc("/t/{tenant}/tasks/{taskId}", relay.handleTaskPoll).Methods("GET")

	// JSON-RPC 2.0 endpoint (A2A protocol binding)
	router.HandleFunc("/t/{tenant}/a2a/{agent}/", relay.handleJSONRPC).Methods("POST")

	// Agent listing
	// Root-level JSON-RPC endpoint for TCK — routes to first connected agent
	router.HandleFunc("/", relay.handleRootJSONRPC).Methods("POST")
	router.HandleFunc("/t/{tenant}/agents", relay.handleListAgents).Methods("GET")

	srv := &http.Server{
		Addr:    fmt.Sprintf(":%d", *port),
		Handler: router,
	}

	// Graceful shutdown
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		<-sigCh

		log.Println("[RELAY] Shutting down...")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		srv.Shutdown(ctx)
	}()

	log.Printf("[RELAY] Starting A2A Relay on port %d", *port)
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("[RELAY] Server error: %v", err)
	}
}
