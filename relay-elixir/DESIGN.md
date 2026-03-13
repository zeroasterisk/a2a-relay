# A2A Relay — Elixir Implementation Design

## Overview

An Elixir/OTP implementation of the A2A Relay server. The relay enables A2A agents
without public URLs to participate in the A2A ecosystem by providing:

1. **WebSocket connections** for agents to register and receive requests
2. **HTTP endpoints** for clients to discover and communicate with connected agents
3. **Offline queuing** (mailbox) for messages when agents are disconnected
4. **JWT authentication** for both agents and clients
5. **Multi-tenancy** — multiple tenants sharing one relay instance

## Why Elixir?

The BEAM VM is arguably the perfect runtime for a relay server:

- **Lightweight processes** — one per WebSocket connection, one per pending request
- **Supervision trees** — self-healing on crashes
- **ETS** — built-in concurrent key-value storage for agent presence, mailboxes
- **Phoenix Channels / Cowboy** — battle-tested WebSocket handling
- **GenServer** — clean stateful process model
- **Hot code upgrades** — deploy without dropping connections (future)
- **Telemetry** — built-in observability primitives

## Architecture

```
                        ┌─────────────────────────────────────┐
                        │           A2A Relay (Elixir)        │
                        │                                      │
  Client HTTP ──────────┤►  Bandit HTTP (Plug Router)         │
  (JSON-RPC)            │     │                                │
                        │     ├── /.well-known/agent.json     │
                        │     ├── POST / (JSON-RPC)           │
                        │     ├── GET /health                 │
                        │     └── GET /status                 │
                        │                                      │
  Agent WebSocket ──────┤►  WebSocket Handler                 │
                        │     ├── Auth (JWT validation)       │
                        │     ├── Agent registration           │
                        │     ├── Request forwarding           │
                        │     └── Response routing             │
                        │                                      │
                        │   ┌─────────────────────────────┐   │
                        │   │     Core Services            │   │
                        │   │  ┌─────────────────────┐    │   │
                        │   │  │ AgentRegistry        │    │   │
                        │   │  │ (ETS + GenServer)    │    │   │
                        │   │  └─────────────────────┘    │   │
                        │   │  ┌─────────────────────┐    │   │
                        │   │  │ RequestRouter        │    │   │
                        │   │  │ (route + track)      │    │   │
                        │   │  └─────────────────────┘    │   │
                        │   │  ┌─────────────────────┐    │   │
                        │   │  │ Mailbox              │    │   │
                        │   │  │ (offline queue)      │    │   │
                        │   │  └─────────────────────┘    │   │
                        │   │  ┌─────────────────────┐    │   │
                        │   │  │ TenantManager        │    │   │
                        │   │  │ (tenant isolation)   │    │   │
                        │   │  └─────────────────────┘    │   │
                        │   └─────────────────────────────┘   │
                        └─────────────────────────────────────┘
```

## OTP Supervision Tree

```
A2ARelay.Application
├── A2ARelay.AgentRegistry (GenServer)
│   └── ETS table: :agent_registry (agent presence + cards)
├── A2ARelay.RequestRouter (GenServer)
│   └── ETS table: :pending_requests (request tracking)
├── A2ARelay.Mailbox (GenServer)
│   └── ETS table: :mailbox (offline message queue)
├── A2ARelay.TenantManager (GenServer)
│   └── ETS table: :tenants (tenant config)
├── A2ARelay.Cleanup (periodic GenServer, hourly)
│   └── Purges expired mailbox messages & task results
├── A2ARelay.Telemetry (telemetry handler setup)
└── Bandit (HTTP server)
    └── A2ARelay.Router (Plug pipeline)
        ├── A2ARelay.Plugs.Auth (JWT validation)
        ├── A2ARelay.Plugs.Tenant (tenant resolution)
        └── A2ARelay.WebSocket.Handler (WebSocket upgrade)
```

## Process Model

### Agent Connection Lifecycle

```
Agent connects via WebSocket
  → Cowboy/Bandit upgrades connection
  → Spawns A2ARelay.WebSocket.Agent process (one per connection)
  → Agent sends auth message with JWT + AgentCard
  → JWT validated (tenant, agent_id, role=agent)
  → Agent registered in AgentRegistry ETS
  → Mailbox drained: queued messages forwarded to agent
  → Connection stays open (ping/pong keepalive)
  → On disconnect: agent deregistered, pending requests failed
```

### Client Request Lifecycle

```
Client sends HTTP POST (JSON-RPC)
  → Plug pipeline validates JWT (role=client)
  → Router extracts tenant + agent_id from URL path
  → RequestRouter checks AgentRegistry for connected agent
  → If connected:
      → Creates PendingRequest with response channel
      → Forwards request to agent via WebSocket
      → Waits on response channel (with timeout)
      → Returns JSON-RPC response to client
  → If disconnected:
      → Queues message in Mailbox
      → Returns task with "submitted" status
      → When agent reconnects, mailbox drains
```

### Per-Agent Process

Each connected agent gets its own process:
- Handles WebSocket frames
- Manages ping/pong (WS-level, not app-level — Cloud Run requirement)
- Routes responses back to pending requests
- Cleans up on termination

## Data Model (ETS Tables)

### `:agent_registry`
```elixir
# Key: {tenant_id, agent_id}
# Value: %{
#   pid: pid(),           # WebSocket handler process
#   agent_card: map(),    # A2A AgentCard
#   connected_at: DateTime.t(),
#   last_ping: DateTime.t()
# }
```

### `:pending_requests`
```elixir
# Key: request_id (UUID)
# Value: %{
#   from: pid(),          # caller process (Plug handler)
#   ref: reference(),     # monitor ref
#   tenant_id: String.t(),
#   agent_id: String.t(),
#   method: String.t(),
#   timeout_at: DateTime.t()
# }
```

### `:mailbox`
```elixir
# Key: {tenant_id, agent_id, message_id}
# Value: %{
#   method: String.t(),
#   params: map(),
#   queued_at: DateTime.t(),
#   from: pid() | nil,     # waiting caller (nil if fire-and-forget)
#   ref: reference() | nil
# }
```

## API Endpoints

### Agent-facing (WebSocket)
- `GET /ws/agent` — WebSocket upgrade for agent connections

### Client-facing (HTTP)
- `GET /:tenant/:agent/.well-known/agent.json` — Agent Card discovery
- `POST /:tenant/:agent/` — JSON-RPC 2.0 (SendMessage, GetTask, etc.)
- `GET /health` — Health check
- `GET /status` — Relay status (connected agents, queue depth)

### Admin (optional, future)
- `GET /admin/agents` — List all connected agents
- `GET /admin/tenants` — List tenants
- `POST /admin/tenants` — Create tenant

## Authentication

### JWT Structure (same as Go relay)
```json
// Agent token
{
  "sub": "agent:tenant:agent-id",
  "tenant": "tenant-id",
  "agent_id": "agent-id",
  "role": "agent",
  "iat": ...,
  "exp": ...
}

// Client token
{
  "sub": "client:tenant:user-id",
  "tenant": "tenant-id",
  "user_id": "user-id",
  "role": "client",
  "scopes": ["message:send", "tasks:read"],
  "iat": ...,
  "exp": ...
}
```

### Auth Flow
1. Agent: JWT in first WebSocket message (`{"type": "auth", "token": "eyJ..."}`)
2. Client: JWT in `Authorization: Bearer <token>` header on HTTP requests
3. Both validated against shared HMAC secret (configurable per-tenant for production)

## Configuration

```elixir
# config/runtime.exs
config :a2a_relay,
  port: System.get_env("PORT", "8080") |> String.to_integer(),
  jwt_secret: System.get_env("RELAY_JWT_SECRET"),
  auth_timeout_ms: 30_000,
  request_timeout_ms: 30_000,
  max_mailbox_messages: 999,
  message_ttl_hours: 216,  # 9 days
  cleanup_interval_ms: 3_600_000,  # 1 hour
  ws_ping_interval_ms: 20_000  # 20s (Cloud Run needs < 60s)
```

## Dependencies

```elixir
defp deps do
  [
    {:bandit, "~> 1.5"},        # HTTP server
    {:plug, "~> 1.14"},         # Request pipeline
    {:websock_adapter, "~> 0.5"}, # WebSocket adapter
    {:jason, "~> 1.4"},         # JSON
    {:joken, "~> 2.6"},         # JWT
    {:telemetry, "~> 1.0"},     # Observability
    {:a2a, "~> 1.0", optional: true}  # A2A types (from our SDK)
  ]
end
```

## Feature Parity with Go Relay

| Feature | Go Relay | Elixir Relay |
|---------|----------|--------------|
| WebSocket agent connections | ✅ | Phase 1 |
| JWT auth (agent + client) | ✅ | Phase 1 |
| JSON-RPC forwarding | ✅ | Phase 1 |
| Agent Card serving | ✅ | Phase 1 |
| Offline mailbox | ✅ | Phase 1 |
| Health endpoint | ✅ | Phase 1 |
| Multi-tenancy | ✅ | Phase 2 |
| SSE streaming pass-through | ❌ | Phase 3 |
| Push notifications | ❌ | Phase 3 |
| WS ping/pong keepalive | ✅ | Phase 1 |
| Task result caching | ✅ | Phase 1 |
| Cleanup loop | ✅ | Phase 1 |

## Advantages Over Go Relay

1. **Process isolation** — one agent crash doesn't affect others
2. **Built-in supervision** — auto-restart on failures
3. **ETS concurrency** — no mutex contention on agent registry
4. **Pattern matching** — cleaner JSON-RPC dispatch
5. **Telemetry integration** — structured metrics out of the box
6. **Hot code reload** — upgrade without dropping connections
7. **Natural async** — GenServer mailboxes for request queuing

## Deployment

### Cloud Run
- Dockerfile with Elixir release (`mix release`)
- Single container, stateless (ETS is ephemeral)
- Min instances = 0 for cost (warm to 1 when needed)
- WebSocket support via Cloud Run's built-in proxy

### Future: Fly.io / bare metal
- Clustering via `libcluster` for multi-node
- Distributed agent registry via `:pg` or Horde
- Persistent mailbox via SQLite or PostgreSQL

## Testing Strategy

1. **Unit tests** — each GenServer in isolation
2. **Integration tests** — full request lifecycle with test WebSocket client
3. **Compatibility tests** — same test suite as Go relay (shared test cases)
4. **Load tests** — concurrent agents + clients via Benchee

## Implementation Phases

### Phase 1: Core (MVP, functional parity with Go)
- Application + supervision tree
- AgentRegistry (ETS-backed GenServer)
- WebSocket handler (auth, registration, request forwarding)
- HTTP router (Plug) with JSON-RPC dispatch
- JWT validation (Joken)
- Mailbox (offline queuing)
- Health endpoint
- Tests + Dockerfile

### Phase 2: Production
- Multi-tenancy with tenant isolation
- Request timeout handling
- Comprehensive error responses
- Telemetry + structured logging
- Status endpoint with metrics

### Phase 3: Advanced
- SSE streaming pass-through
- Push notification forwarding
- Agent Card caching + TTL
- Rate limiting
- Admin API
