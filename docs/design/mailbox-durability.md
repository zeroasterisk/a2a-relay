# A2A Mailbox Durability Design

## Current State

The relay uses **in-memory mailboxes**:
- `map[string]*Mailbox` — keyed by `tenant:agent_id`
- Each mailbox is a `[]*QueuedMessage` slice with a mutex
- Max 999 messages per agent, 9-day TTL
- 30s sync wait for flappy reconnections
- `ResponseCh chan *A2AResponse` for synchronous client waiting
- Cleanup loop runs every hour

### What Breaks

| Scenario | Impact |
|----------|--------|
| Relay restarts (deploy, crash, OOM) | **All queued messages lost** |
| Cloud Run scales to 0 | Same — all state gone |
| Cloud Run scales to N>1 | Agents on instance A can't receive messages sent to instance B |
| Process panic | All state gone, no recovery |

**Current reality**: Relay on Cloud Run with `min-instances=0` means every cold start loses all mailboxes. Even with `min-instances=1`, deploys restart the instance.

---

## Design Goals

1. **Durable**: Messages survive relay restarts
2. **Concurrent**: Multiple agents connecting simultaneously without contention
3. **Ordered**: Messages delivered in order per agent
4. **Exactly-once**: No duplicate delivery (or at-least-once with idempotency)
5. **Bounded**: Max messages per agent, TTL enforcement
6. **Observable**: Know how many messages are queued, oldest message age
7. **Simple**: Minimal operational complexity (this runs on one instance)

## Non-Goals

- Multi-region replication (single instance is fine)
- Sub-millisecond latency (10ms is acceptable)
- Millions of messages (hundreds per agent is the scale)

---

## Option Analysis

### A: SQLite (Recommended)

```
Relay Process
├── SQLite WAL-mode database
│   ├── messages table (durable queue)
│   ├── task_results table
│   └── agents table (registration cache)
└── In-memory maps (hot connections only)
```

**Pros:**
- Zero external dependencies
- Survives restarts (file on disk)
- WAL mode handles concurrent reads/writes well
- Fly.io + Litestream = automatic S3 replication
- Go has excellent SQLite support (`modernc.org/sqlite` — pure Go, no CGO)
- Transactions for exactly-once delivery

**Cons:**
- Single-writer (WAL helps but still one write at a time)
- Doesn't help with multi-instance (but we don't need it)

**Schema:**
```sql
CREATE TABLE messages (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    method TEXT NOT NULL,
    params BLOB NOT NULL,
    queued_at INTEGER NOT NULL,  -- unix ms
    delivered_at INTEGER,        -- null = pending
    response BLOB,               -- null = no response yet
    response_at INTEGER,
    expires_at INTEGER NOT NULL
);

CREATE INDEX idx_messages_pending ON messages(tenant_id, agent_id, delivered_at)
    WHERE delivered_at IS NULL;

CREATE TABLE task_results (
    id TEXT PRIMARY KEY,
    response BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

-- Agent registration cache (survives restarts)
CREATE TABLE agents (
    tenant_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    agent_card BLOB,
    last_connected_at INTEGER,
    PRIMARY KEY (tenant_id, agent_id)
);
```

**Delivery flow:**
```
1. Client sends message
2. INSERT into messages table
3. Return 202 Accepted with task ID immediately
4. If agent connected: notify via channel, agent reads from DB
5. Agent responds: UPDATE messages SET response = ?, delivered_at = NOW()
6. Client polls or gets response via ResponseCh
7. On agent reconnect: SELECT * FROM messages WHERE delivered_at IS NULL ORDER BY queued_at
```

### B: Upstash Redis

**Pros:** Multi-instance support, pub/sub for notifications
**Cons:** External dependency, ~$10/mo, network latency, Redis streams complexity
**Verdict:** Overkill for single-instance. Good for future multi-instance.

### C: Embedded NATS JetStream

**Pros:** Built for exactly-once messaging, consumer groups
**Cons:** Heavy dependency, complex for simple queue, Go binary size increases significantly
**Verdict:** Too much machinery.

### D: BoltDB/bbolt

**Pros:** Embedded Go KV store, simple
**Cons:** Single process only, no SQL, custom serialization needed, less flexible than SQLite
**Verdict:** SQLite is strictly better for this use case.

---

## Recommended: SQLite with WAL

### Implementation Plan

#### Phase 1: Durable Queue (core)
1. Add SQLite dependency (`modernc.org/sqlite`)
2. Create `store.go` with `MessageStore` interface
3. Implement SQLite store with connection pooling
4. Migrate `QueueMessage()` to INSERT into SQLite
5. Migrate `FlushMailbox()` to SELECT + UPDATE
6. Keep `ResponseCh` pattern for synchronous waiting (in-memory channels are fine)
7. On startup: load pending messages from SQLite

#### Phase 2: Delivery Guarantees
1. **At-least-once**: Don't mark delivered until agent ACKs
2. **Dedup on client side**: Include message ID in response, clients can dedup
3. **Retry with backoff**: If agent disconnects mid-delivery, message goes back to pending
4. **Dead letter**: After N delivery attempts, move to dead_letter table

#### Phase 3: Observability
1. `/metrics` endpoint: pending count per agent, oldest message, delivery latency
2. Structured logging: message lifecycle events
3. Health check includes queue depth

### Concurrency Model

```
Write path:  Client → INSERT message → notify agent channel
Read path:   Agent connects → SELECT pending → deliver → UPDATE delivered_at
Cleanup:     Background goroutine → DELETE expired every hour
```

SQLite WAL mode allows concurrent reads with one writer. Since writes are INSERT/UPDATE (fast), contention is minimal. The in-memory `ResponseCh` handles the synchronous waiting pattern without touching the DB.

### Migration Path

1. Keep current in-memory mailbox as fallback
2. Add `RELAY_STORE=sqlite` env var (default: `memory`)
3. SQLite store implements same `MessageStore` interface
4. Feature flag allows rollback
5. Once stable, remove in-memory implementation

### Fly.io Deployment

```toml
# fly.toml
[mounts]
  source = "relay_data"
  destination = "/data"

[env]
  RELAY_STORE = "sqlite"
  RELAY_DB_PATH = "/data/relay.db"
```

With Litestream for backup:
```yaml
# litestream.yml
dbs:
  - path: /data/relay.db
    replicas:
      - url: s3://a2a-relay-backups/relay.db
```

### Security Considerations

- SQLite file permissions: 0600
- DB path outside web root
- No SQL injection risk (parameterized queries only)
- Backup encryption for S3 replicas
- Message content is opaque BLOB (relay doesn't inspect payloads)

---

## Capacity Planning

| Metric | Current | With SQLite |
|--------|---------|-------------|
| Max messages/agent | 999 | 999 (configurable) |
| Message TTL | 9 days | 9 days (configurable) |
| Restart recovery | ❌ Lost | ✅ Persisted |
| Deploy downtime | ~30s (messages lost) | ~5s (messages preserved) |
| Storage per message | ~2KB RAM | ~2KB disk |
| Max DB size (1000 agents × 999 msgs) | N/A | ~2GB |

## Open Questions

1. Should we keep `ResponseCh` for sync waiting, or switch to polling-only?
   - **Recommendation**: Keep both. ResponseCh for connected clients, polling for disconnected.
2. Should message content be encrypted at rest?
   - **Recommendation**: Not initially. Relay already requires auth to access messages.
3. Should we implement message priority?
   - **Recommendation**: Not yet. FIFO is sufficient. Add later if needed.
