# Deployment Guide

This guide covers deploying the A2A relay on various platforms. Pick what fits your needs and budget.

## What the Relay Needs

Before choosing a platform, understand the relay's requirements:

| Requirement | Why | Impact on Hosting |
|-------------|-----|-------------------|
| **WebSocket support** | Agents connect via persistent WS | Rules out pure-HTTP platforms |
| **Long-lived connections** | Agent WS stays open indefinitely | Needs keep-alive or reconnect support |
| **Low latency** | User is waiting for agent response | Prefer edge/regional deployment |
| **JWT validation** | Auth for agents and clients | Minimal CPU, no special runtime |
| **Minimal compute** | Relay just routes messages | Tiny resource footprint (~50MB RAM) |
| **No persistent storage** | State is in-memory (connected agents, pending requests) | Stateless deployment OK |

**The relay is small** — ~900 lines of Go (or equivalent TS). It holds WebSocket connections and routes HTTP requests to connected agents. No database, no disk, no heavy compute.

### The Cold Start Problem

If you use scale-to-zero hosting, the relay process dies when idle. This means:
- All agent WebSocket connections drop
- Agents must detect disconnection and reconnect
- First request after idle triggers a cold start (seconds of latency)
- During cold start, no agents are connected → requests fail until agents reconnect

**This is the key trade-off:** scale-to-zero saves money but degrades the experience. Always-on costs more but "just works."

---

## Platform Comparison

| Platform | Runtime | WS Support | Cold Start | Cost (minimal) | Effort |
|----------|---------|------------|------------|-----------------|--------|
| **Cloud Run** (scale-to-zero) | Go, TS, any | ✅ | 3-10s | **$0** (free tier) | Low |
| **Cloud Run** (min-instances=1) | Go, TS, any | ✅ | None | **$5-7/mo** | Low |
| **Fly.io** | Go, TS, any | ✅ | ~300ms | **$0** (free tier) | Low |
| **Cloudflare Workers + DO** | TS only | ✅ (hibernated) | None | **~$5/mo** | Medium |
| **Vercel** (Edge Functions) | TS only | ⚠️ Limited | ~100ms | **$0** (free tier) | Medium |
| **Railway** | Go, TS, any | ✅ | None | **$5/mo** | Low |
| **Render** | Go, TS, any | ✅ | ~30s (free) | **$0-7/mo** | Low |
| **Self-hosted** (VPS/NAS) | Any | ✅ | None | Varies | Medium |

---

## Cloud Run (Current Default)

The Go relay is deployed on Cloud Run today. See [`relay-go/DEPLOYMENT.md`](../relay-go/DEPLOYMENT.md) for full details (secrets, IAM, testing).

### Scale-to-Zero (Default)

```bash
gcloud run deploy a2a-relay \
  --source=./relay-go \
  --region=us-central1 \
  --allow-unauthenticated \
  --set-env-vars="JWT_SECRET=$SECRET"
```

- **Cost:** $0 at low usage (free tier: 2M requests, 360k vCPU-sec/mo)
- **Trade-off:** Cold starts kill WS connections; agents must reconnect

### Always-On (min-instances=1)

```bash
gcloud run services update a2a-relay \
  --region=us-central1 \
  --min-instances=1
```

- **Cost:** ~$5-7/mo (idle billing: ~$0.0064/vCPU-hr + ~$0.0007/GiB-hr)
- **Trade-off:** Paying for idle, but no cold starts

### WebSocket Keepalive

Cloud Run kills idle connections. The relay sends WS-level pings every 30s to keep connections alive. This is handled automatically — no configuration needed.

---

## Fly.io

Runs Docker containers with fast cold starts. No rewrite needed — deploy the Go binary directly.

### Deploy

```bash
# Install flyctl
curl -L https://fly.io/install.sh | sh

# From relay-go/
cd relay-go
fly launch --name a2a-relay --region ord

# Set secret
fly secrets set JWT_SECRET="your-secret"

# Deploy
fly deploy
```

### Fly.toml

```toml
[build]
  dockerfile = "Dockerfile"

[env]
  PORT = "8080"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = true    # scale to zero
  auto_start_machines = true   # wake on request
  min_machines_running = 0

[[services]]
  protocol = "tcp"
  internal_port = 8080

  [[services.ports]]
    port = 443
    handlers = ["tls", "http"]
```

- **Cost:** Free tier includes 3 shared-cpu VMs (256MB each)
- **Cold start:** ~300ms (much faster than Cloud Run)
- **WS support:** Native, no special config
- **Scale-to-zero:** Yes, with fast wake

---

## Cloudflare Workers + Durable Objects

Best long-term option for persistent WebSocket connections. **Requires the TypeScript relay implementation.**

Durable Objects provide "hibernatable WebSockets" — the WS connection stays alive but you're not billed while idle. Purpose-built for this use case.

### Architecture

```
Client HTTP → Worker (routes request) → Durable Object (holds agent WS)
Agent WS  → Worker (upgrades) ────────→ Durable Object (manages connection)
```

### Example Structure

```typescript
// src/relay.ts — Durable Object
export class RelayRoom {
  private agents: Map<string, WebSocket> = new Map();

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    
    if (request.headers.get("Upgrade") === "websocket") {
      return this.handleAgentWS(request);
    }
    
    // Route A2A request to connected agent
    return this.handleClientRequest(request);
  }

  async webSocketMessage(ws: WebSocket, message: string) {
    // Handle agent responses — Durable Object wakes from hibernation
  }

  async webSocketClose(ws: WebSocket) {
    // Clean up agent registration
  }
}

// src/worker.ts — Entry point
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const id = env.RELAY.idFromName("global"); // or per-tenant
    const relay = env.RELAY.get(id);
    return relay.fetch(request);
  }
};
```

### Deploy

```bash
npx wrangler deploy
```

### wrangler.toml

```toml
name = "a2a-relay"
main = "src/worker.ts"

[[durable_objects.bindings]]
name = "RELAY"
class_name = "RelayRoom"

[[migrations]]
tag = "v1"
new_classes = ["RelayRoom"]

[vars]
JWT_SECRET = ""  # Use wrangler secret put JWT_SECRET
```

- **Cost:** $5/mo (Workers Paid plan) + negligible usage at low volume
- **Cold start:** None (Durable Object hibernates but WS stays alive)
- **WS support:** First-class with hibernation (zero idle cost)
- **Global edge:** Automatic

---

## Vercel (Edge Functions)

Possible with the TypeScript relay, but with limitations.

### Constraints

- **No native WebSocket server** — Edge Functions are request/response, not long-lived
- **Workaround:** Use Vercel + a WebSocket service (e.g., Ably, Pusher, PartyKit)
- **Function timeout:** 30s (Hobby), 300s (Pro)
- **Better fit:** If you only need HTTP polling (no agent WS connections)

### With PartyKit (Vercel-Adjacent)

[PartyKit](https://partykit.io) is Cloudflare DO under the hood, by Vercel's team:

```typescript
// party/relay.ts
import type * as Party from "partykit/server";

export default class RelayServer implements Party.Server {
  async onConnect(conn: Party.Connection) {
    // Handle agent WebSocket connection
  }

  async onMessage(message: string, sender: Party.Connection) {
    // Route messages between agents and clients
  }

  async onRequest(req: Party.Request) {
    // Handle HTTP A2A requests from clients
  }
}
```

- **Cost:** Free tier available, $20/mo Pro
- **Essentially Cloudflare DO** with a nicer DX

---

## Self-Hosted (VPS, NAS, Home Server)

If you already run infrastructure (like an OpenClaw instance on a NAS), run the relay alongside it.

### Docker Compose

```yaml
services:
  a2a-relay:
    build: ./relay-go
    ports:
      - "8080:8080"
    environment:
      - JWT_SECRET=${JWT_SECRET}
    restart: unless-stopped
```

### With Cloudflare Tunnel (No Public IP Needed)

```bash
# Install cloudflared
cloudflared tunnel create a2a-relay
cloudflared tunnel route dns a2a-relay relay.yourdomain.com

# Run tunnel
cloudflared tunnel --url http://localhost:8080 run a2a-relay
```

- **Cost:** $0 (Cloudflare Tunnel is free)
- **Cold start:** None (always running)
- **Trade-off:** Depends on your infra reliability; no auto-scaling

---

## Recommendations

### For Personal Use (1-2 agents, low traffic)

**Fly.io free tier** — zero cost, fast cold starts, runs Go binary as-is.

### For Production (multiple agents, reliability matters)

**Cloudflare Workers + Durable Objects** — $5/mo, hibernatable WS, zero idle cost, global edge. Requires TS relay.

### For "Just Make It Work" 

**Cloud Run min-instances=1** — $5-7/mo, no changes to current setup, one command:
```bash
gcloud run services update a2a-relay --region=us-central1 --min-instances=1
```

### For Maximum Control

**Self-hosted + Cloudflare Tunnel** — $0, always-on, runs anywhere Docker runs.
