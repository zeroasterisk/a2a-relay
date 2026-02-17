# Tech Debt Backlog - a2a-relay

Generated: 2026-02-16

## High Priority

### Configuration
- [ ] **main.go:26** - JWT secret has empty default value
  - ✅ Already requires env var or flag (good practice)
  - Consider: add minimum length validation (currently accepts any length)

## Medium Priority

### Error Handling
- [ ] **WebSocket handlers** - Some error paths don't close connections properly
  - Audit all `conn.WriteJSON` calls for error handling
- [ ] **handleA2ARequest** - Should log full error details in structured format
  - Currently uses `log.Printf` - consider structured logging

### Security
- [ ] Add rate limiting per tenant/agent
- [ ] Add request size limits to prevent DoS
- [ ] Consider adding IP allowlisting option

### Observability
- [ ] Add Prometheus metrics endpoint
- [ ] Add structured logging (JSON format option)
- [ ] Add trace correlation IDs

## Low Priority

### Code Quality
- [ ] Extract magic numbers to constants:
  - Ping/pong intervals (30s, 60s)
  - Request timeout (30s default)
  - Auth timeout (30s default)
- [ ] Add godoc comments to exported types
- [ ] Consider splitting main.go into multiple files (handlers, types, relay)

### Testing
- [ ] Add integration tests for WebSocket handlers
- [ ] Add load testing for concurrent agents
- [ ] Add chaos testing for reconnection scenarios

### Features (Future)
- [ ] Add admin endpoint for listing all agents across tenants
- [ ] Add WebSocket compression support
- [ ] Add optional message persistence/replay

## Notes
- No hardcoded credentials found ✅
- JWT validation properly implemented ✅
- Cloud Run keepalive properly implemented ✅
- Graceful shutdown implemented ✅
