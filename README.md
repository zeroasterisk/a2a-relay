# A2A Relay

> ⚠️ **Beta** — Tested and working, but API may change. Production use at your own risk.

A relay service for [A2A Protocol](https://a2a-protocol.org) that enables agents without public URLs to participate in agent-to-agent communication.

## Why?

A2A assumes HTTP endpoints, but many agents can't expose public URLs:
- Behind NAT/firewalls
- Laptops that sleep
- Privacy-conscious deployments

**Solution:** Agents connect *outbound* to the relay. Clients send requests to the relay, which forwards to connected agents.

```
Client ──HTTP──► Relay ◄──WebSocket── Agent (no public URL)
```

## Quick Start

### Deploy the Relay

```bash
cd relay-go
go build -o a2a-relay .
./a2a-relay --port 8080 --secret "your-32-char-jwt-secret"
```

Or use Docker:
```bash
docker run -p 8080:8080 -e JWT_SECRET="your-secret" ghcr.io/zeroasterisk/a2a-relay
```

### Connect an Agent

```javascript
const ws = new WebSocket('wss://your-relay.com/agent');
ws.send(JSON.stringify({
  type: 'auth',
  token: createJWT({ tenant: 'default', agent_id: 'my-agent', role: 'agent' }),
  tenant: 'default',
  agent_id: 'my-agent',
  agent_card: { name: 'My Agent', ... }
}));
```

### Send a Message (Client)

```bash
curl -X POST https://your-relay.com/t/default/a2a/my-agent/message/send \
  -H "Authorization: Bearer $CLIENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message": {"role": "user", "parts": [{"text": "Hello!"}]}}'
```

## OpenClaw Integration

The easiest way to use A2A Relay is with [OpenClaw](https://openclaw.ai):

```json
{
  "channels": {
    "a2a": {
      "enabled": true,
      "accounts": {
        "default": {
          "relayUrl": "wss://your-relay.com/agent",
          "relaySecret": "your-jwt-secret",
          "agentId": "my-agent"
        }
      }
    }
  }
}
```

See [openclaw-a2a plugin](https://github.com/zeroasterisk/zaf/tree/main/plugins/a2a) for details.

## Architecture

```
Relay
├── Tenant: acme-corp
│   ├── Agent: assistant (WebSocket)
│   └── Agent: researcher (WebSocket)
└── Tenant: personal
    └── Agent: my-bot (WebSocket)
```

### Auth Model

| Token | Who | Allows |
|-------|-----|--------|
| Agent | Agent process | Register & receive requests |
| Client | End users | Send requests to agents |

Tokens are JWTs signed with the relay's secret.

## API

### Agent WebSocket (`/agent`)

```json
// Auth
{ "type": "auth", "token": "...", "tenant": "...", "agent_id": "...", "agent_card": {...} }

// Receive request
{ "type": "a2a.request", "payload": { "id": "...", "params": {...} } }

// Send response
{ "type": "a2a.response", "payload": { "id": "...", "result": {...} } }
```

### Client HTTP (`/t/{tenant}/a2a/{agent}`)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/.well-known/agent.json` | Agent card |
| POST | `/message/send` | Send message |
| GET | `/tasks/{id}` | Get task |
| GET | `/tasks` | List tasks |

## Implementations

| Directory | Language | Status |
|-----------|----------|--------|
| `/relay-go` | Go | ✅ Production-ready |
| `/relay-elixir` | Elixir | 🚧 WIP |
| `/relay-restate` | TypeScript | 🚧 WIP |

## Config

```bash
# Environment variables
JWT_SECRET=your-32-char-minimum-secret
PORT=8080
BIND=0.0.0.0
```

## Links

- [A2A Protocol](https://a2a-protocol.org)
- [OpenClaw A2A Plugin](https://github.com/zeroasterisk/zaf/tree/main/plugins/a2a)
- [A2A OPT Extension](https://github.com/zeroasterisk/a2a-opt)

## License

Apache-2.0
