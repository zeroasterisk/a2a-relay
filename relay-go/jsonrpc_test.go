package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/gorilla/mux"
	"github.com/gorilla/websocket"
)

func newTestRelay() *Relay {
	return NewRelay("test-secret-key")
}

func newTestRouter(r *Relay) *mux.Router {
	router := mux.NewRouter()
	router.HandleFunc("/t/{tenant}/a2a/{agent}/", r.handleJSONRPC).Methods("POST")
	router.HandleFunc("/", r.handleRootJSONRPC).Methods("POST")
	return router
}

func postJSONRPC(router http.Handler, path string, req interface{}) *httptest.ResponseRecorder {
	body, _ := json.Marshal(req)
	r := httptest.NewRequest("POST", path, bytes.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	return w
}

func postJSONRPCWithAuth(router http.Handler, path, token string, req interface{}) *httptest.ResponseRecorder {
	body, _ := json.Marshal(req)
	r := httptest.NewRequest("POST", path, bytes.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	return w
}

func decodeResponse(t *testing.T, w *httptest.ResponseRecorder) JSONRPCResponse {
	t.Helper()
	var resp JSONRPCResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("Failed to decode response: %v, body: %s", err, w.Body.String())
	}
	return resp
}

// --- Parse error tests ---

func TestJSONRPC_ParseError(t *testing.T) {
	relay := newTestRelay()
	router := newTestRouter(relay)

	r := httptest.NewRequest("POST", "/t/test/a2a/agent1/", bytes.NewReader([]byte("not json")))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)

	resp := decodeResponse(t, w)
	if resp.Error == nil {
		t.Fatal("Expected error response")
	}
	if resp.Error.Code != -32700 {
		t.Errorf("Expected code -32700, got %d", resp.Error.Code)
	}
}

// --- Invalid request tests ---

func TestJSONRPC_InvalidVersion(t *testing.T) {
	relay := newTestRelay()
	router := newTestRouter(relay)

	w := postJSONRPC(router, "/t/test/a2a/agent1/", map[string]interface{}{
		"jsonrpc": "1.0",
		"method":  "SendMessage",
		"id":      1,
	})

	resp := decodeResponse(t, w)
	if resp.Error == nil || resp.Error.Code != -32600 {
		t.Errorf("Expected -32600, got %+v", resp.Error)
	}
}

func TestJSONRPC_MissingID(t *testing.T) {
	relay := newTestRelay()
	router := newTestRouter(relay)

	w := postJSONRPC(router, "/t/test/a2a/agent1/", map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "SendMessage",
	})

	resp := decodeResponse(t, w)
	if resp.Error == nil || resp.Error.Code != -32600 {
		t.Errorf("Expected -32600, got %+v", resp.Error)
	}
}

func TestJSONRPC_MissingMethod(t *testing.T) {
	relay := newTestRelay()
	router := newTestRouter(relay)

	w := postJSONRPC(router, "/t/test/a2a/agent1/", map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
	})

	resp := decodeResponse(t, w)
	if resp.Error == nil || resp.Error.Code != -32600 {
		t.Errorf("Expected -32600, got %+v", resp.Error)
	}
}

// --- Method not found ---

func TestJSONRPC_MethodNotFound(t *testing.T) {
	relay := newTestRelay()
	router := newTestRouter(relay)

	w := postJSONRPC(router, "/t/test/a2a/agent1/", map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "NonExistentMethod",
		"id":      1,
	})

	resp := decodeResponse(t, w)
	if resp.Error == nil || resp.Error.Code != -32601 {
		t.Errorf("Expected -32601, got %+v", resp.Error)
	}
}

// --- Method mapping ---

func TestJSONRPC_MethodMapping(t *testing.T) {
	cases := map[string]string{
		"SendMessage": "message/send",
		"GetTask":     "tasks/get",
		"CancelTask":  "tasks/cancel",
		"ListTasks":   "tasks/list",
	}
	for method, expected := range cases {
		if got := jsonrpcMethodMap[method]; got != expected {
			t.Errorf("Method %q: expected %q, got %q", method, expected, got)
		}
	}
}

// --- Auth errors (no token) ---

func TestJSONRPC_NoAuth(t *testing.T) {
	relay := newTestRelay()
	router := newTestRouter(relay)

	w := postJSONRPC(router, "/t/test/a2a/agent1/", map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "SendMessage",
		"id":      1,
	})

	resp := decodeResponse(t, w)
	if resp.Error == nil || resp.Error.Code != -32603 {
		t.Errorf("Expected -32603 (unauthorized), got %+v", resp.Error)
	}
}

// --- GetExtendedAgentCard (no auth needed, but agent must be online) ---

func TestJSONRPC_GetExtendedAgentCard_AgentOffline(t *testing.T) {
	relay := newTestRelay()
	router := newTestRouter(relay)

	w := postJSONRPC(router, "/t/test/a2a/agent1/", map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "GetExtendedAgentCard",
		"id":      1,
	})

	resp := decodeResponse(t, w)
	if resp.Error == nil || resp.Error.Code != -32603 {
		t.Errorf("Expected -32603, got %+v", resp.Error)
	}
}

func TestJSONRPC_GetExtendedAgentCard_Success(t *testing.T) {
	relay := newTestRelay()
	router := newTestRouter(relay)

	// Register a fake agent (no real websocket needed for card lookup)
	card := &AgentCard{
		Name:        "TestAgent",
		Description: "A test agent",
		URL:         "http://localhost",
		Version:     "1.0",
	}
	relay.RegisterAgent("test", "agent1", nil, card)
	defer relay.UnregisterAgent("test", "agent1")

	w := postJSONRPC(router, "/t/test/a2a/agent1/", map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "GetExtendedAgentCard",
		"id":      1,
	})

	resp := decodeResponse(t, w)
	if resp.Error != nil {
		t.Fatalf("Unexpected error: %+v", resp.Error)
	}
	if resp.Result == nil {
		t.Fatal("Expected result")
	}

	var resultCard AgentCard
	if err := json.Unmarshal(resp.Result, &resultCard); err != nil {
		t.Fatalf("Failed to unmarshal card: %v", err)
	}
	if resultCard.Name != "TestAgent" {
		t.Errorf("Expected name TestAgent, got %s", resultCard.Name)
	}
}

// --- Root JSON-RPC endpoint ---

func TestRootJSONRPC_NoAgents(t *testing.T) {
	relay := newTestRelay()
	router := newTestRouter(relay)

	w := postJSONRPC(router, "/", map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "SendMessage",
		"id":      1,
	})

	resp := decodeResponse(t, w)
	if resp.Error == nil || resp.Error.Code != -32603 {
		t.Errorf("Expected -32603, got %+v", resp.Error)
	}
}

func TestRootJSONRPC_ParseError(t *testing.T) {
	relay := newTestRelay()
	// Register an agent so we get past that check
	relay.RegisterAgent("t", "a", nil, nil)
	defer relay.UnregisterAgent("t", "a")

	router := newTestRouter(relay)
	r := httptest.NewRequest("POST", "/", bytes.NewReader([]byte("bad")))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)

	resp := decodeResponse(t, w)
	if resp.Error == nil || resp.Error.Code != -32700 {
		t.Errorf("Expected -32700, got %+v", resp.Error)
	}
}

func TestRootJSONRPC_MethodNotFound(t *testing.T) {
	relay := newTestRelay()
	relay.RegisterAgent("t", "a", nil, nil)
	defer relay.UnregisterAgent("t", "a")

	router := newTestRouter(relay)
	w := postJSONRPC(router, "/", map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "Nope",
		"id":      1,
	})

	resp := decodeResponse(t, w)
	if resp.Error == nil || resp.Error.Code != -32601 {
		t.Errorf("Expected -32601, got %+v", resp.Error)
	}
}

// --- jsonrpcError helper ---

func TestJsonrpcErrorHelper(t *testing.T) {
	resp := jsonrpcError(42, -32600, "bad request")
	if resp.JSONRPC != "2.0" {
		t.Errorf("Expected jsonrpc 2.0")
	}
	if resp.ID != 42 {
		t.Errorf("Expected id 42, got %v", resp.ID)
	}
	if resp.Error.Code != -32600 {
		t.Errorf("Expected code -32600")
	}
	if resp.Error.Message != "bad request" {
		t.Errorf("Expected message 'bad request'")
	}
	if resp.Result != nil {
		t.Errorf("Expected nil result")
	}
}

// --- Integration test with mock agent via WebSocket ---

func TestJSONRPC_SendMessage_Integration(t *testing.T) {
	relay := newTestRelay()
	router := mux.NewRouter()
	router.HandleFunc("/t/{tenant}/a2a/{agent}/", relay.handleJSONRPC).Methods("POST")
	router.HandleFunc("/agent", relay.handleAgentWebSocket)

	srv := httptest.NewServer(router)
	defer srv.Close()

	// Generate a valid JWT for tenant "demo"
	token := generateTestJWT(t, relay, "demo", "bot1")

	// Connect a mock agent via WebSocket
	wsURL := "ws" + srv.URL[4:] + "/agent"
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("WebSocket dial failed: %v", err)
	}
	defer ws.Close()

	// Send auth
	ws.WriteJSON(map[string]interface{}{
		"type":     "auth",
		"token":    token,
		"agent_id": "bot1",
		"agent_card": map[string]interface{}{
			"name":    "Bot1",
			"url":     "http://localhost",
			"version": "1.0",
			"capabilities": map[string]bool{},
		},
	})

	// Read auth_ok
	var authResp map[string]interface{}
	ws.ReadJSON(&authResp)
	if authResp["type"] != "auth_ok" {
		t.Fatalf("Expected auth_ok, got %v", authResp)
	}

	// Start a goroutine to handle the agent side
	go func() {
		for {
			var msg map[string]json.RawMessage
			if err := ws.ReadJSON(&msg); err != nil {
				return
			}
			msgType := ""
			json.Unmarshal(msg["type"], &msgType)
			if msgType == "a2a.request" {
				var req A2ARequest
				json.Unmarshal(msg["payload"], &req)
				// Echo back a success response
				ws.WriteJSON(map[string]interface{}{
					"type": "a2a.response",
					"payload": map[string]interface{}{
						"id":     req.ID,
						"result": map[string]string{"status": "completed"},
					},
				})
			}
		}
	}()

	// Give agent time to register
	time.Sleep(50 * time.Millisecond)

	// Send JSON-RPC request
	rpcBody, _ := json.Marshal(map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "SendMessage",
		"params":  map[string]interface{}{"message": map[string]string{"text": "hello"}},
		"id":      1,
	})

	req, _ := http.NewRequest("POST", srv.URL+"/t/demo/a2a/bot1/", bytes.NewReader(rpcBody))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Request failed: %v", err)
	}
	defer resp.Body.Close()

	var rpcResp JSONRPCResponse
	json.NewDecoder(resp.Body).Decode(&rpcResp)

	if rpcResp.Error != nil {
		t.Fatalf("Unexpected error: %+v", rpcResp.Error)
	}
	if rpcResp.JSONRPC != "2.0" {
		t.Errorf("Expected jsonrpc 2.0, got %s", rpcResp.JSONRPC)
	}
	if rpcResp.Result == nil {
		t.Fatal("Expected result")
	}

	var result map[string]string
	json.Unmarshal(rpcResp.Result, &result)
	if result["status"] != "completed" {
		t.Errorf("Expected status completed, got %s", result["status"])
	}
}

// generateTestJWT creates a valid JWT for testing
func generateTestJWT(t *testing.T, relay *Relay, tenant, agentID string) string {
	t.Helper()
	claims := jwt.MapClaims{
		"tenant":   tenant,
		"agent_id": agentID,
		"exp":      time.Now().Add(1 * time.Hour).Unix(),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := tok.SignedString(relay.jwtSecret)
	if err != nil {
		t.Fatalf("Failed to sign JWT: %v", err)
	}
	return signed
}
