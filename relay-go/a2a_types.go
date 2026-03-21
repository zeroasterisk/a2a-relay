package main

import (
	"time"
)

// SendMessageRequest represents a request for the SendMessage method
type SendMessageRequest struct {
	Message       Message                   `json:"message"`
	Configuration *SendMessageConfiguration `json:"configuration,omitempty"`
	Metadata      map[string]interface{}    `json:"metadata,omitempty"`
}

// SendMessageConfiguration configures a send request
type SendMessageConfiguration struct {
	AcceptedOutputModes        []string                    `json:"acceptedOutputModes,omitempty"`
	TaskPushNotificationConfig *TaskPushNotificationConfig `json:"taskPushNotificationConfig,omitempty"`
	HistoryLength              *int32                      `json:"historyLength,omitempty"`
	ReturnImmediately          bool                        `json:"returnImmediately,omitempty"`
}

// Message is one unit of communication between client and server
type Message struct {
	MessageID        string                 `json:"messageId"`
	ContextID        string                 `json:"contextId,omitempty"`
	TaskID           string                 `json:"taskId,omitempty"`
	Role             string                 `json:"role"`
	Parts            []Part                 `json:"parts"`
	Metadata         map[string]interface{} `json:"metadata,omitempty"`
	Extensions       []string               `json:"extensions,omitempty"`
	ReferenceTaskIDs []string               `json:"referenceTaskIds,omitempty"`
}

// Part represents a container for a section of communication content
type Part struct {
	Text      string                 `json:"text,omitempty"`
	Raw       []byte                 `json:"raw,omitempty"`
	URL       string                 `json:"url,omitempty"`
	Data      interface{}            `json:"data,omitempty"`
	Metadata  map[string]interface{} `json:"metadata,omitempty"`
	Filename  string                 `json:"filename,omitempty"`
	MediaType string                 `json:"mediaType,omitempty"`
}

// TaskPushNotificationConfig associates a push notification with a task
type TaskPushNotificationConfig struct {
	Tenant         string              `json:"tenant,omitempty"`
	ID             string              `json:"id,omitempty"`
	TaskID         string              `json:"taskId,omitempty"`
	URL            string              `json:"url"`
	Token          string              `json:"token,omitempty"`
	Authentication *AuthenticationInfo `json:"authentication,omitempty"`
}

// AuthenticationInfo defines authentication details
type AuthenticationInfo struct {
	Scheme      string `json:"scheme"`
	Credentials string `json:"credentials,omitempty"`
}

// Task is the core unit of action for A2A
type Task struct {
	ID        string                 `json:"id"`
	ContextID string                 `json:"contextId,omitempty"`
	Status    TaskStatus             `json:"status"`
	Artifacts []Artifact             `json:"artifacts,omitempty"`
	History   []Message              `json:"history,omitempty"`
	Metadata  map[string]interface{} `json:"metadata,omitempty"`
}

// TaskStatus is a container for the status of a task
type TaskStatus struct {
	State     string     `json:"state"`
	Message   *Message   `json:"message,omitempty"`
	Timestamp *time.Time `json:"timestamp,omitempty"`
}

// Artifact represents a task output
type Artifact struct {
	ArtifactID  string                 `json:"artifactId"`
	Name        string                 `json:"name,omitempty"`
	Description string                 `json:"description,omitempty"`
	Parts       []Part                 `json:"parts"`
	Metadata    map[string]interface{} `json:"metadata,omitempty"`
	Extensions  []string               `json:"extensions,omitempty"`
}

// SendMessageResponse represents the response for the SendMessage method
type SendMessageResponse struct {
	Task    *Task    `json:"task,omitempty"`
	Message *Message `json:"message,omitempty"`
}

// GetTaskRequest represents a request for the GetTask method
type GetTaskRequest struct {
	ID            string `json:"id"`
	HistoryLength *int32 `json:"historyLength,omitempty"`
}

// ListTasksRequest represents a request for the ListTasks method
type ListTasksRequest struct {
	ContextID            string     `json:"contextId,omitempty"`
	Status               string     `json:"status,omitempty"`
	PageSize             int32      `json:"pageSize,omitempty"`
	PageToken            string     `json:"pageToken,omitempty"`
	HistoryLength        *int32     `json:"historyLength,omitempty"`
	StatusTimestampAfter *time.Time `json:"statusTimestampAfter,omitempty"`
	IncludeArtifacts     bool       `json:"includeArtifacts,omitempty"`
}

// ListTasksResponse represents a response for the ListTasks method
type ListTasksResponse struct {
	Tasks         []Task `json:"tasks"`
	NextPageToken string `json:"nextPageToken,omitempty"`
	PageSize      int32  `json:"pageSize"`
	TotalSize     int32  `json:"totalSize"`
}

// CancelTaskRequest represents a request for the CancelTask method
type CancelTaskRequest struct {
	ID       string                 `json:"id"`
	Metadata map[string]interface{} `json:"metadata,omitempty"`
}

// StreamResponse encapsulates different types of response data in streaming
type StreamResponse struct {
	Task           *Task                    `json:"task,omitempty"`
	Message        *Message                 `json:"message,omitempty"`
	StatusUpdate   *TaskStatusUpdateEvent   `json:"statusUpdate,omitempty"`
	ArtifactUpdate *TaskArtifactUpdateEvent `json:"artifactUpdate,omitempty"`
}

// TaskStatusUpdateEvent is sent by the agent to notify the client of a task status change
type TaskStatusUpdateEvent struct {
	TaskID    string                 `json:"taskId"`
	ContextID string                 `json:"contextId"`
	Status    TaskStatus             `json:"status"`
	Metadata  map[string]interface{} `json:"metadata,omitempty"`
}

// TaskArtifactUpdateEvent is a task delta where an artifact has been generated
type TaskArtifactUpdateEvent struct {
	TaskID    string                 `json:"taskId"`
	ContextID string                 `json:"contextId"`
	Artifact  Artifact               `json:"artifact"`
	Append    bool                   `json:"append,omitempty"`
	LastChunk bool                   `json:"lastChunk,omitempty"`
	Metadata  map[string]interface{} `json:"metadata,omitempty"`
}

// GetTaskPushNotificationConfigRequest represents a request for the GetTaskPushNotificationConfig method
type GetTaskPushNotificationConfigRequest struct {
	TaskID string `json:"taskId"`
	ID     string `json:"id"`
}

// DeleteTaskPushNotificationConfigRequest represents a request for the DeleteTaskPushNotificationConfig method
type DeleteTaskPushNotificationConfigRequest struct {
	TaskID string `json:"taskId"`
	ID     string `json:"id"`
}

// ListTaskPushNotificationConfigsRequest represents a request for the ListTaskPushNotificationConfigs method
type ListTaskPushNotificationConfigsRequest struct {
	TaskID    string `json:"taskId"`
	PageSize  int32  `json:"pageSize,omitempty"`
	PageToken string `json:"pageToken,omitempty"`
}

// ListTaskPushNotificationConfigsResponse represents the response for the ListTaskPushNotificationConfigs method
type ListTaskPushNotificationConfigsResponse struct {
	Configs       []TaskPushNotificationConfig `json:"configs"`
	NextPageToken string                       `json:"nextPageToken,omitempty"`
}

// SubscribeToTaskRequest represents a request for the SubscribeToTask method
type SubscribeToTaskRequest struct {
	ID string `json:"id"`
}
