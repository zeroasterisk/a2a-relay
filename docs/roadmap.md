# Roadmap

Current state and planned direction for the A2A relay.

## Current State

| Implementation | Language | Status | Notes |
|---------------|----------|--------|-------|
| `relay-go` | Go | ✅ Production | Deployed on Cloud Run (dev + prod) |
| `relay-elixir` | Elixir | 📋 Planned | Placeholder only |
| `relay-restate` | TypeScript | 📋 Planned | Placeholder only |

### What Works Today (relay-go)

- Agent WebSocket connections with JWT auth
- Client HTTP requests (message/send, tasks, agent cards)
- Multi-tenant isolation
- WS-level keepalive for Cloud Run
- Graceful shutdown
- A2A protocol compliance (message/send, tasks)

### What's Missing

See [`BACKLOG.md`](../BACKLOG.md) for the full tech debt list. Key gaps:

- No message queuing (offline agents = dropped messages)
- No streaming support (SSE)
- No rate limiting
- No structured logging / metrics
- In-memory only (no persistence across restarts)

---

## Short Term: TypeScript Relay

**Priority: High** — Unlocks Cloudflare Workers, Vercel, and broader contributor access.

### Why TypeScript?

1. **Platform reach** — Cloudflare Workers (Durable Objects), Vercel Edge, Deno Deploy all require JS/TS
2. **Contributor base** — More people write TS than Go
3. **A2A ecosystem** — JS/TS A2A SDKs are actively developed
4. **Feature parity** — Same ~900 lines of logic, different runtime

### Approach

Port `relay-go/main.go` to TypeScript with platform adapters:

```
relay-ts/
├── src/
│   ├── relay.ts          # Core logic (agent registry, message routing)
│   ├── auth.ts           # JWT validation
│   ├── types.ts          # A2A types, WebSocket messages
│   └── adapters/
│       ├── node.ts       # Node.js / Express / Fastify
│       ├── cloudflare.ts # Workers + Durable Objects
│       └── vercel.ts     # Edge Functions (+ PartyKit)
├── test/
│   └── ...               # Shared test suite (see below)
├── wrangler.toml         # Cloudflare config
└── package.json
```

**Core logic is platform-agnostic.** Adapters handle:
- WebSocket server setup (Node ws, CF WebSocket API, etc.)
- HTTP routing (Express, Workers fetch, etc.)
- State storage (in-memory, Durable Object storage, etc.)

### Shared Test Suite

Tests should be language-agnostic so Go and TS relays pass the same suite. Extend the existing `tests/` directory:

```
tests/
├── test_message_send.py    # Existing
├── test_streaming.py
├── test_auth.py
├── test_reconnection.py
├── test_multi_tenant.py
└── conftest.py             # Relay URL as fixture
```

Run against any relay implementation:
```bash
RELAY_URL=http://localhost:8080 pytest tests/
```

---

## Near Term: Per-Agent Auth & Sender Identity

**Priority: High** — Current shared-secret model doesn't scale to multiple senders.

### Problem

Today: one JWT secret per tenant. Anyone with it can impersonate any agent or send as any sender. Fine for single-user dev, breaks for multi-agent production.

### Requirements

1. **Many senders** — multiple clients (proxies, UIs, other agents) can send messages
2. **No impersonation** — sender A can't pretend to be sender B, and no one can pretend to be the receiving agent
3. **Easy onboarding** — adding a new sender shouldn't require touching every config

### Proposed Design: API Keys + Agent Binding

```
Tenant: tck
├── Agent "zaf" ← bound to agent key (only this key can connect as zaf)
├── Sender key "proxy-1" ← can send TO any agent, identity stamped as "proxy-1"
├── Sender key "web-ui" ← can send TO any agent, identity stamped as "web-ui"
└── Sender key "other-agent" ← can send TO any agent, identity stamped as "other-agent"
```

**Key types:**
- **Agent key** — can connect via WebSocket as a specific agent ID. One key per agent. Used by OpenClaw gateways.
- **Sender key** — can send messages via HTTP to any agent. Cannot connect as an agent. Identity is stamped by the relay (not self-reported). Used by proxies, UIs, external clients.

**Onboarding flow:**
1. Relay admin creates tenant + first agent key (CLI or API)
2. Admin generates sender keys as needed (`relay keys create --tenant tck --name "proxy-1" --role sender`)
3. Sender uses key as Bearer token — relay stamps sender identity automatically

**What changes:**
- JWT claims include `role: "agent" | "sender"` and `identity: "<name>"`
- Relay enforces: only `role: agent` can open WebSocket connections
- Relay stamps `sender` identity on messages (clients can't forge it)
- Agent keys are bound to a specific agent ID (can't connect as someone else)

**Migration:** Existing shared-secret JWTs continue to work as "admin" role (backward compatible). New key types are opt-in.

---

## Medium Term: Reliability

### Message Queuing

When an agent is offline, queue messages and deliver on reconnect.

| Backend | Best For |
|---------|----------|
| In-memory | Dev/testing (current behavior — messages dropped) |
| SQLite | Single-node deployments |
| Durable Object storage | Cloudflare deployments |
| Redis | Multi-node with shared state |

### Streaming (SSE)

A2A supports streaming responses via SSE. The relay needs to:
1. Accept SSE request from client
2. Forward to agent via WS
3. Stream WS responses back as SSE events
4. Handle backpressure

### Agent Discovery

Agents advertise capabilities via agent cards. The relay could:
- Serve a directory of available agents per tenant
- Support capability-based routing ("find me an agent that can search the web")
- Federate discovery across relays

---

## Long Term: Federation & Scale

### Multi-Relay Federation

Multiple relays discover each other and route across boundaries:

```
Relay A (Cloudflare)          Relay B (Self-hosted)
├── Agent: assistant    ←───→  ├── Agent: researcher
└── Agent: coder               └── Agent: home-automation
```

Agents on Relay A can talk to agents on Relay B. Requires:
- Relay-to-relay auth
- Agent card propagation
- Routing protocol (which relay has which agent?)

### Horizontal Scaling

For high-traffic deployments:
- **Cloudflare:** Automatic (Durable Objects scale per-tenant)
- **Cloud Run / Fly:** Multiple instances with shared state (Redis/Postgres)
- **Challenge:** WebSocket affinity (agent connected to instance A, request hits instance B)

### Admin & Observability

- Admin dashboard (connected agents, message rates, errors)
- Prometheus metrics endpoint
- Structured logging (JSON)
- Trace correlation (request → relay → agent → response)
- Alerting (agent disconnected, high error rate)

---

## Non-Goals

Things the relay explicitly should NOT do:

- **Agent logic** — The relay routes messages, it doesn't process them
- **Message transformation** — Pass-through only, no content modification
- **Long-term storage** — Queue is temporary; use external storage for audit logs
- **Authentication provider** — Relay validates JWTs, doesn't issue them (bring your own secret)

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02 | Go for initial implementation | Single binary, fast, good WS libraries |
| 2026-02 | JWT-based auth | Simple, stateless, no external dependencies |
| 2026-02 | Multi-tenant from day one | Avoid costly retrofit later |
| 2026-02 | TypeScript relay planned | Unlock Cloudflare/Vercel, broaden contributors |
