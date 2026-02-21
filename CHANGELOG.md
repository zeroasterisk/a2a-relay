# Changelog

## 2026-02-21 — Security Hardening

- **V1:** Root JSON-RPC (`POST /`) now requires Bearer token auth, scoped to caller's tenant
- **V2:** Agent directory (`GET /`, `GET /.well-known/agents`) requires auth, returns only caller's tenant agents
- **V4:** Agent WebSocket: `agent_id` enforced from JWT claims, not from WS auth message
- **V5:** All tokens must include `exp` claim; max 24h expiry window enforced
- **V10:** Fixed potential panic in `handleListAgents` on short Authorization header
- **V12:** Agent re-registration logs warning and closes old connection instead of silent replacement
