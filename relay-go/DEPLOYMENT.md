# A2A Relay Deployment

## Cloud Run Services

| Environment | URL | Status |
|-------------|-----|--------|
| **Dev** | https://a2a-relay-dev-442090395636.us-central1.run.app | ✅ Running |
| **Prod** | https://a2a-relay-prod-442090395636.us-central1.run.app | ✅ Running |

## JWT Secrets

Secrets are configured as environment variables on Cloud Run via Secret Manager.

**⚠️ Never commit secrets to the repository!**

```bash
# Set secret via Cloud Run
gcloud run services update a2a-relay-dev \
  --region=us-central1 \
  --set-env-vars="RELAY_JWT_SECRET=your-secret-here"

# Or use Secret Manager (recommended for production)
gcloud secrets create a2a-relay-jwt-secret --replication-policy=automatic
echo -n "your-secret" | gcloud secrets versions add a2a-relay-jwt-secret --data-file=-
```

## Generating JWT Tokens

### For Agent Connection

```bash
# Using jwt-cli or similar
jwt encode --secret "$RELAY_JWT_SECRET" '{
  "sub": "agent:tenant-id:agent-id",
  "tenant": "tenant-id",
  "agent_id": "agent-id",
  "role": "agent",
  "iat": 1739581200,
  "exp": 1742173200
}'
```

### For Client Requests

```bash
jwt encode --secret "$RELAY_JWT_SECRET" '{
  "sub": "client:tenant-id:user-id",
  "tenant": "tenant-id",
  "user_id": "user-id",
  "role": "client",
  "scopes": ["message:send", "tasks:read"],
  "iat": 1739581200,
  "exp": 1739667600
}'
```

## Testing

```bash
# Health check (public endpoint)
curl https://a2a-relay-dev-442090395636.us-central1.run.app/health

# Root endpoint (API docs)
curl https://a2a-relay-dev-442090395636.us-central1.run.app/
```

## IAM Configuration

Public access requires IAM policy binding:

```bash
gcloud beta run services add-iam-policy-binding \
  --region=us-central1 \
  --member=allUsers \
  --role=roles/run.invoker \
  --project=your-project-id \
  a2a-relay-dev
```

## Timeouts

| Timeout | Default | Environment Variable |
|---------|---------|---------------------|
| Auth timeout | 30s | (flag: `-auth-timeout`) |
| Request timeout | 30s | (flag: `-request-timeout`) |
| WS keepalive | 30s | (hardcoded) |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Cloud Run (A2A Relay)                    │
│                                                              │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐   │
│  │ /agent (WS) │     │ /t/{t}/a2a/ │     │  /health    │   │
│  │ Agent conn  │────►│ Client API  │◄────│  Monitoring │   │
│  └─────────────┘     └─────────────┘     └─────────────┘   │
│         │                   │                               │
│         ▼                   ▼                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Relay (in-memory)                       │   │
│  │  - agents map[tenantID:agentID]*ConnectedAgent       │   │
│  │  - pendingRequests map[requestID]*PendingRequest     │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

Agent (behind NAT)                     Client (anywhere)
      │                                       │
      │ WSS connect + auth                    │ HTTPS + JWT
      │                                       │
      ▼                                       ▼
┌──────────────┐                      ┌──────────────┐
│  wss://.../  │                      │ POST /t/.../ │
│    agent     │                      │ message/send │
└──────────────┘                      └──────────────┘
```

## Security Best Practices

1. **Rotate secrets regularly** — especially after any exposure
2. **Use Secret Manager** — don't hardcode secrets in env vars
3. **Monitor access logs** — Cloud Run provides request logging
4. **Set up alerts** — for unusual traffic patterns

## Next Steps

1. **Create agent client library** (Python/JS for connecting agents)
2. **Add queue storage** (SQLite/Redis for offline agents)
3. **Add metrics** (Cloud Monitoring, latency, success rates)
