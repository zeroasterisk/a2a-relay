# A2A Relay - Go Implementation

Lightweight A2A relay server in Go.

## Features

- Multi-tenant agent registration via WebSocket
- HTTP A2A facade for clients
- JWT authentication for agents and clients
- Request/response forwarding with timeout

## Quick Start

```bash
# Set JWT secret
export RELAY_JWT_SECRET="your-secret-here"

# Run
go run .

# Or build and run
go build -o relay-server
./relay-server -port 8080
```

## Docker

```bash
docker build -t a2a-relay .
docker run -p 8080:8080 -e RELAY_JWT_SECRET=secret a2a-relay
```

## API

### Agent WebSocket

```
ws://localhost:8080/agent
```

Auth message:
```json
{
  "type": "auth",
  "token": "eyJ...",
  "agent_id": "my-agent",
  "agent_card": { "name": "My Agent", ... }
}
```

### Client HTTP

```bash
# Get agent card
curl http://localhost:8080/t/{tenant}/a2a/{agent}/.well-known/agent.json

# Send message
curl -X POST http://localhost:8080/t/{tenant}/a2a/{agent}/message/send \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  -d '{"message": {"parts": [{"text": "Hello"}]}}'

# List agents in tenant
curl http://localhost:8080/t/{tenant}/agents \
  -H "Authorization: Bearer eyJ..."
```

## JWT Claims

Agent token:
```json
{
  "tenant": "acme-corp",
  "agent_id": "zaf",
  "role": "agent"
}
```

Client token:
```json
{
  "tenant": "acme-corp",
  "user_id": "alan",
  "role": "client"
}
```

## URL Scheme

Agents registered with this relay are accessible at:

```
a2a-relay://{host}/t/{tenant}/{agent_id}
```

Example: `a2a-relay://relay.openclaw.ai/t/personal/zaf`
