# A2A Relay Design

## Design Goals

1. **Multi-tenant**: Many humans/teams, many agents, shared infrastructure
2. **Simple auth**: JWT tokens for agents and clients
3. **Protocol compliant**: Full A2A spec support
4. **Offline handling**: Queue messages when agent disconnected
5. **Observable**: Metrics, logs, traces

## Auth Deep Dive

### Identity Model

```
┌─────────────────────────────────────────────────────────────┐
│                          Relay                              │
│  ┌───────────────────────────────────────────────────────┐ │
│  │                    Tenant: acme-corp                   │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────────┐  │ │
│  │  │ Agent: zaf  │ │Agent: bot-1 │ │ Agent: bot-2    │  │ │
│  │  │ (owner:alan)│ │(owner:team) │ │ (owner:team)    │  │ │
│  │  └─────────────┘ └─────────────┘ └─────────────────┘  │ │
│  │                                                        │ │
│  │  Clients: [alan, bob, carol, ...]                     │ │
│  │  Admins: [alan]                                       │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │                    Tenant: personal                    │ │
│  │  ┌───────────────┐                                    │ │
│  │  │ Agent: my-bot │                                    │ │
│  │  └───────────────┘                                    │ │
│  │  Clients: [me], Admins: [me]                          │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Token Structure (JWT)

**Agent Token:**
```json
{
  "sub": "agent:acme-corp:zaf",
  "tenant": "acme-corp",
  "agent_id": "zaf",
  "role": "agent",
  "iat": 1707955200,
  "exp": 1710547200
}
```

**Client Token:**
```json
{
  "sub": "client:acme-corp:alan",
  "tenant": "acme-corp",
  "user_id": "alan",
  "role": "client",
  "scopes": ["message:send", "tasks:read"],
  "iat": 1707955200,
  "exp": 1708560000
}
```

**Admin Token:**
```json
{
  "sub": "admin:acme-corp:alan",
  "tenant": "acme-corp",
  "user_id": "alan",
  "role": "admin",
  "iat": 1707955200,
  "exp": 1708560000
}
```

### Auth Flows

#### 1. Agent Registration

```
Agent                          Relay
  │                              │
  │ WSS connect                  │
  ├─────────────────────────────►│
  │                              │
  │ { type: "auth",              │
  │   token: "eyJ...",           │
  │   agent_card: {...} }        │
  ├─────────────────────────────►│
  │                              │ Validate JWT
  │                              │ Check tenant exists
  │                              │ Register agent in presence
  │                              │
  │ { type: "auth_ok",           │
  │   agent_id: "zaf" }          │
  │◄─────────────────────────────┤
  │                              │
  │ (connection stays open)      │
```

#### 2. Client Request

```
Client                         Relay                         Agent
  │                              │                              │
  │ POST /t/acme/a2a/zaf/message │                              │
  │ Authorization: Bearer eyJ... │                              │
  ├─────────────────────────────►│                              │
  │                              │ Validate JWT                 │
  │                              │ Check client in tenant       │
  │                              │ Check agent connected        │
  │                              │                              │
  │                              │ { type: "a2a.request", ... } │
  │                              ├─────────────────────────────►│
  │                              │                              │
  │                              │ { type: "a2a.response", ...} │
  │                              │◄─────────────────────────────┤
  │                              │                              │
  │ 200 OK { ... }               │                              │
  │◄─────────────────────────────┤                              │
```

### Scopes

| Scope | Description |
|-------|-------------|
| `message:send` | Send messages to agents |
| `message:stream` | Use streaming endpoints |
| `tasks:read` | Read task status |
| `tasks:write` | Cancel tasks |
| `agents:read` | List available agents |

## Message Queuing

### Online Agent

```
Request → Route to agent WS → Wait for response → Return
```

### Offline Agent (with queue enabled)

```
Request → Queue in tenant mailbox → Return 202 Accepted with task_id
         │
         └─► When agent connects:
             Queue → Deliver to agent → Store response
             │
             └─► Client polls GET /tasks/{id} for result
```

### Queue Storage Options

| Backend | Durability | Latency | Complexity |
|---------|-----------|---------|------------|
| Memory | None (lost on restart) | <1ms | Low |
| SQLite | Disk | ~1ms | Low |
| Redis | Optional | ~1ms | Medium |
| Postgres | Full | ~2ms | Medium |

**Recommendation:** SQLite for single-node, Postgres for multi-node.

## Streaming

### SSE (Server-Sent Events)

```
Client                         Relay                         Agent
  │                              │                              │
  │ POST /t/acme/a2a/zaf/stream  │                              │
  │ Accept: text/event-stream    │                              │
  ├─────────────────────────────►│                              │
  │                              │                              │
  │ ◄── SSE connection open ──── │ ◄── WS request ────────────►│
  │                              │                              │
  │ data: {"task": {...}}        │ ◄── WS: task created ────── │
  │◄─────────────────────────────┤                              │
  │                              │                              │
  │ data: {"status": {...}}      │ ◄── WS: status update ───── │
  │◄─────────────────────────────┤                              │
  │                              │                              │
  │ data: {"artifact": {...}}    │ ◄── WS: artifact ────────── │
  │◄─────────────────────────────┤                              │
  │                              │                              │
  │ (stream closes on complete)  │                              │
```

## Implementation Comparison

### Elixir/Phoenix

**Pros:**
- Perfect process model (each agent = process)
- Built-in PubSub (Phoenix.PubSub)
- Built-in presence (Phoenix.Presence)
- Hot code reload
- Fault tolerance (supervisors)

**Cons:**
- No A2A SDK (build from scratch)
- Smaller ecosystem
- Deployment less familiar to some

**Architecture:**
```
Phoenix App
├── AgentSocket (Phoenix.Socket)
│   └── AgentChannel (one per agent)
├── A2AController (HTTP endpoints)
├── PresenceServer (GenServer tracking agents)
├── QueueServer (GenServer for offline queue)
└── TenantStore (ETS/Mnesia/Postgres)
```

### Go

**Pros:**
- A2A SDK available
- Single binary
- Familiar to many
- Good performance

**Cons:**
- More boilerplate for WebSocket
- Manual PubSub implementation
- Less elegant concurrency model

**Architecture:**
```
Go App
├── ws/ (gorilla/websocket)
│   └── AgentHandler
├── http/ (chi router)
│   └── A2AHandler
├── auth/ (JWT validation)
├── presence/ (sync.Map + channels)
└── queue/ (SQLite or Redis)
```

### Restate

**Pros:**
- Durable by default
- Automatic retries
- State management built-in
- TypeScript SDK

**Cons:**
- Different mental model
- Requires Restate server
- WebSocket handling less native

**Architecture:**
```
Restate Service
├── AgentService (virtual object per agent)
│   ├── connect() - WebSocket shim
│   ├── sendMessage() - durable handler
│   └── getStatus()
├── TenantService
│   └── listAgents()
└── AuthMiddleware
```

## Evaluation Plan

1. **Build MVP in each** (2-3 days each)
   - Agent WS connection + auth
   - Single endpoint: POST /message/send
   - No queue (online only)

2. **Benchmark**
   - Connections: How many concurrent agents?
   - Latency: Request → Response time
   - Memory: Per-connection overhead

3. **Evaluate**
   - Code complexity
   - Deployment simplicity
   - Extensibility

## Decision Criteria

| Criteria | Weight | Elixir | Go | Restate |
|----------|--------|--------|-----|---------|
| Concurrency model | 25% | ⭐⭐⭐ | ⭐⭐ | ⭐⭐ |
| A2A SDK available | 15% | ⭐ | ⭐⭐⭐ | ⭐⭐ |
| Deployment simplicity | 20% | ⭐⭐ | ⭐⭐⭐ | ⭐⭐ |
| Durability | 15% | ⭐⭐ | ⭐⭐ | ⭐⭐⭐ |
| Team familiarity | 15% | ⭐⭐⭐ | ⭐⭐ | ⭐ |
| Ecosystem/community | 10% | ⭐⭐ | ⭐⭐⭐ | ⭐⭐ |

## Next Steps

1. Create directory structure for each implementation
2. Define shared test suite (language-agnostic)
3. Implement Elixir MVP first (Alan's preference)
4. Implement Go MVP
5. Implement Restate MVP
6. Benchmark and decide
