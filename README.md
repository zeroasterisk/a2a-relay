# A2A Relay

A relay service for A2A (Agent2Agent) protocol that enables agents without public URLs to participate in the A2A ecosystem.

## The Problem

A2A assumes HTTP endpoints, but many agents don't have public URLs:
- Behind NAT (home networks, corporate firewalls)
- Laptops that sleep/wake
- Privacy-conscious deployments

## The Solution

Agents connect **outbound** to the relay via WebSocket. Clients send A2A requests to the relay's HTTP API, which forwards them to the connected agent.

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│  A2A Client  │  HTTP   │   A2A Relay  │   WS    │    Agent     │
│              │────────►│              │◄────────│  (no public  │
│              │◄────────│              │────────►│     URL)     │
└──────────────┘         └──────────────┘         └──────────────┘
```

## Architecture

### Multi-tenant Auth Model

```
Relay
├── Tenant: acme-corp
│   ├── Agent: zaf (connected via WS)
│   ├── Agent: research-bot (connected via WS)
│   └── Clients: [user1, user2, ...]
├── Tenant: personal
│   ├── Agent: my-assistant (connected via WS)
│   └── Clients: [me]
└── Tenant: public
    └── Agent: demo-bot (connected via WS)
```

### Auth Flows

**Agent → Relay (WebSocket)**
```
1. Agent connects: wss://relay.example.com/agent
2. Agent sends: { "auth": { "tenant": "acme", "agent_id": "zaf", "token": "..." } }
3. Relay validates token, registers agent in tenant
4. Agent receives A2A requests, sends responses
```

**Client → Relay (HTTP)**
```
1. Client calls: POST /t/{tenant}/a2a/{agent_id}/message/send
2. Headers: Authorization: Bearer <client_token>
3. Relay validates client belongs to tenant
4. Relay forwards to agent, returns response
```

### Token Types

| Token Type | Who Has It | What It Allows |
|------------|-----------|----------------|
| Agent Token | Agent | Register as specific agent in tenant |
| Client Token | End users | Send A2A requests to agents in tenant |
| Admin Token | Tenant admin | Manage agents, create tokens |

## Implementations

This repo will contain multiple implementations to evaluate tradeoffs:

### `/relay-elixir` - Phoenix/Elixir

**Best for:** High concurrency, real-time, mailbox queuing

- Phoenix Channels for WebSocket
- Built-in PubSub (no Redis needed)
- Millions of concurrent connections
- Erlang's actor model = perfect for agent mailboxes

### `/relay-go` - Go

**Best for:** Simple deployment, A2A SDK available

- Uses official A2A Go SDK
- Single binary
- Good concurrency with goroutines
- Simpler than Elixir for many devs

### `/relay-restate` - Restate

**Best for:** Durable execution, guaranteed delivery

- Messages survive relay restart
- Automatic retries with backoff
- Built-in state management
- Higher complexity

## API Specification

### Agent WebSocket API

**Endpoint:** `wss://relay.example.com/agent`

**Auth Message:**
```json
{
  "type": "auth",
  "tenant": "acme-corp",
  "agent_id": "zaf",
  "token": "agent-token-...",
  "agent_card": { ... }
}
```

**Receive Request:**
```json
{
  "type": "a2a.request",
  "id": "req-123",
  "method": "message/send",
  "params": { ... }
}
```

**Send Response:**
```json
{
  "type": "a2a.response",
  "id": "req-123",
  "result": { ... }
}
```

### Client HTTP API

**Base URL:** `https://relay.example.com/t/{tenant}/a2a/{agent_id}`

| Method | Path | Description |
|--------|------|-------------|
| GET | `/.well-known/agent.json` | Get agent card |
| POST | `/message/send` | Send message |
| POST | `/message/stream` | Send with SSE streaming |
| GET | `/tasks/{id}` | Get task |
| GET | `/tasks` | List tasks |
| POST | `/tasks/{id}/cancel` | Cancel task |

### Admin HTTP API

**Base URL:** `https://relay.example.com/admin/t/{tenant}`

| Method | Path | Description |
|--------|------|-------------|
| GET | `/agents` | List registered agents |
| POST | `/agents/{id}/token` | Generate agent token |
| DELETE | `/agents/{id}/token` | Revoke agent token |
| GET | `/clients` | List clients |
| POST | `/clients/{id}/token` | Generate client token |

## URL Scheme

Agents and clients reference relay-hosted agents with:

```
a2a-relay://{relay-host}/t/{tenant}/{agent_id}
```

Example: `a2a-relay://relay.openclaw.ai/t/personal/zaf`

## Configuration

```yaml
# relay.yaml
server:
  host: 0.0.0.0
  port: 8080
  
auth:
  # JWT signing key
  secret: "${RELAY_AUTH_SECRET}"
  
  # Token expiry
  agent_token_ttl: 30d
  client_token_ttl: 7d

tenants:
  # Pre-configured tenants (optional)
  - id: personal
    name: "Personal"
    admin_email: "alan@example.com"

storage:
  # Where to store tenant/token data
  type: sqlite  # or postgres, memory
  path: ./relay.db

limits:
  # Per-tenant limits
  max_agents_per_tenant: 10
  max_clients_per_tenant: 100
  max_pending_requests: 1000
  request_timeout_ms: 30000
```

## Development

```bash
# Elixir version
cd relay-elixir
mix deps.get
mix phx.server

# Go version
cd relay-go
go run .

# Restate version
cd relay-restate
npm install
npx restate-server &
npm run dev
```

## License

Apache-2.0
