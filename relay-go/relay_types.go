package main

import (
	"encoding/json"
	"time"
)

// WSMessage is a generic WebSocket message wrapper
type WSMessage struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

// WSAuthOK is sent when an agent authenticates successfully
type WSAuthOK struct {
	Type    string `json:"type"`
	AgentID string `json:"agent_id"`
	Tenant  string `json:"tenant"`
}

// WSError is sent when an error occurs in the WebSocket connection
type WSError struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

// WSPong is sent in response to a ping
type WSPong struct {
	Type string `json:"type"`
}

// RelayQueuedResponse is returned when a message is queued for an offline agent
type RelayQueuedResponse struct {
	Status  string `json:"status"`
	TaskID  string `json:"task_id"`
	Message string `json:"message,omitempty"`
}

// RelayTaskPollResponse is returned when polling a queued task's status
type RelayTaskPollResponse struct {
	Status   string       `json:"status"`
	TaskID   string       `json:"task_id"`
	Response *A2AResponse `json:"response,omitempty"`
}

// RelayHealthResponse is returned by the /health endpoint
type RelayHealthResponse struct {
	Status          string `json:"status"`
	Version         string `json:"version"`
	AgentsConnected int    `json:"agents_connected"`
	PendingRequests int    `json:"pending_requests"`
	QueuedMessages  int    `json:"queued_messages"`
	CompletedTasks  int    `json:"completed_tasks"`
}

// RelayAgentInfo represents an agent's basic info for listing
type RelayAgentInfo struct {
	ID           string            `json:"id"`
	ConnectedAt  time.Time         `json:"connected_at,omitempty"`
	CardURL      string            `json:"cardUrl,omitempty"`
	URL          string            `json:"url,omitempty"`
	Name         string            `json:"name,omitempty"`
	Description  string            `json:"description,omitempty"`
	Skills       []AgentSkill      `json:"skills,omitempty"`
	Capabilities AgentCapabilities `json:"capabilities,omitempty"`
}

// RelayInfoResponse is returned by the / endpoint
type RelayInfoResponse struct {
	Name      string            `json:"name"`
	Version   string            `json:"version"`
	Docs      string            `json:"docs"`
	Message   string            `json:"message,omitempty"`
	Tenant    string            `json:"tenant,omitempty"`
	Agents    []RelayAgentInfo  `json:"agents,omitempty"`
	Endpoints map[string]string `json:"endpoints"`
}

// RelayAgentIndexResponse is returned by the /.well-known/agents endpoint
type RelayAgentIndexResponse struct {
	Agents []RelayAgentInfo `json:"agents"`
	Count  int              `json:"count"`
}
