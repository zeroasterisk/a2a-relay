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
	Name               string            `json:"name"`
	Description        string            `json:"description,omitempty"`
	URL                string            `json:"url"`
	Version            string            `json:"version"`
	Capabilities       AgentCapabilities `json:"capabilities"`
	Skills             []AgentSkill      `json:"skills,omitempty"`
	DefaultInputModes  []string          `json:"defaultInputModes,omitempty"`
	DefaultOutputModes []string          `json:"defaultOutputModes,omitempty"`
}

type AgentCapabilities struct {
	Streaming         bool `json:"streaming,omitempty"`
	PushNotifications bool `json:"pushNotifications,omitempty"`
}

type AgentSkill struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
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

// Relay manages agents and requests
type Relay struct {
	agents          map[string]*ConnectedAgent // key: tenantID:agentID
	pendingRequests map[string]*PendingRequest
	jwtSecret       []byte
	mu              sync.RWMutex
	upgrader        websocket.Upgrader
}

func NewRelay(jwtSecret string) *Relay {
	return &Relay{
		agents:          make(map[string]*ConnectedAgent),
		pendingRequests: make(map[string]*PendingRequest),
		jwtSecret:       []byte(jwtSecret),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
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

	// Read loop - handle responses and pings
	for {
		var msg map[string]json.RawMessage
		if err := conn.ReadJSON(&msg); err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("[RELAY] Agent %s read error: %v", agentID, err)
			}
			break
		}

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

	// Find agent
	agent := r.GetAgent(tenantID, agentID)
	if agent == nil {
		http.Error(w, `{"error":"agent_offline"}`, http.StatusServiceUnavailable)
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

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(agent.AgentCard)
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

func (r *Relay) handleHealth(w http.ResponseWriter, req *http.Request) {
	r.mu.RLock()
	agentCount := len(r.agents)
	pendingCount := len(r.pendingRequests)
	r.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":           "ok",
		"version":          "0.1.0",
		"agents_connected": agentCount,
		"pending_requests": pendingCount,
	})
}

func (r *Relay) handleRoot(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"name":    "A2A Relay",
		"version": "0.1.0",
		"docs":    "https://github.com/zeroasterisk/a2a-relay",
		"endpoints": map[string]string{
			"health":     "GET /health",
			"agent_ws":   "WS /agent",
			"agent_card": "GET /t/{tenant}/a2a/{agent}/.well-known/agent.json",
			"send":       "POST /t/{tenant}/a2a/{agent}/message/send",
			"stream":     "POST /t/{tenant}/a2a/{agent}/message/stream",
			"list":       "GET /t/{tenant}/agents",
		},
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
	router.HandleFunc("/t/{tenant}/a2a/{agent}/.well-known/agent.json", relay.handleAgentCard).Methods("GET")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/message/send", relay.handleA2ARequest).Methods("POST")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/message/stream", relay.handleA2ARequest).Methods("POST")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/tasks/{task}", relay.handleA2ARequest).Methods("GET")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/tasks", relay.handleA2ARequest).Methods("GET")
	router.HandleFunc("/t/{tenant}/a2a/{agent}/tasks/{task}/cancel", relay.handleA2ARequest).Methods("POST")

	// Agent listing
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
