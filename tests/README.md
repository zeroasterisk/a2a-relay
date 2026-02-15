# A2A Relay Test Suite

Language-agnostic test suite for validating any relay implementation.

## Running Tests

```bash
# Set relay URL
export RELAY_URL=http://localhost:8080

# Run all tests
./run-tests.sh

# Run specific test
./run-tests.sh test_agent_connect
```

## Test Categories

### 1. Agent Connection Tests

- `test_agent_connect` - Agent can connect via WebSocket
- `test_agent_auth_valid` - Valid token allows connection
- `test_agent_auth_invalid` - Invalid token rejects connection
- `test_agent_reconnect` - Agent can reconnect after disconnect
- `test_agent_presence` - Agent appears in presence list

### 2. Client Request Tests

- `test_message_send` - Client can send message to online agent
- `test_message_send_auth` - Request requires valid client token
- `test_message_send_offline` - Request to offline agent returns 503 (or queues)
- `test_message_stream` - Streaming response works

### 3. Multi-tenant Tests

- `test_tenant_isolation` - Client in tenant A can't reach agent in tenant B
- `test_tenant_create` - Admin can create tenant
- `test_tenant_tokens` - Admin can generate agent/client tokens

### 4. Performance Tests

- `test_concurrent_agents` - 1000 concurrent agent connections
- `test_concurrent_requests` - 1000 concurrent client requests
- `test_latency` - P50/P99 latency under load

## Test Fixtures

### Agent Card

```json
{
  "name": "Test Agent",
  "description": "Agent for testing",
  "skills": [
    {
      "id": "echo",
      "name": "Echo",
      "description": "Echoes back the message"
    }
  ],
  "capabilities": {
    "streaming": true
  }
}
```

### Mock Agent Behavior

The test agent:
1. Connects to relay
2. On `message/send`: Returns `{ "message": { "parts": [{ "text": "Echo: {input}" }] } }`
3. On `message/stream`: Streams 3 status updates then completes

## Implementation Checklist

Each implementation must pass all tests:

- [ ] `relay-elixir`
- [ ] `relay-go`  
- [ ] `relay-restate`
