# Customer User Journeys (CUJs)

This document captures critical end-to-end user scenarios that should remain validated, either through automated tests or manual verification.

## Purpose

CUJs describe real-world user workflows that exercise multiple system components. When automated e2e tests become too brittle or expensive to maintain, the scenarios should still be documented here to guide manual testing and future test development.

## Research Agent CUJ

**Status**: Not currently covered by automated tests (e2e test was in .broken state and has been removed)

**Scenario**: Multi-agent collaboration with a research agent

### User Story
As a client user, I want to send a request to an assistant agent that delegates research tasks to a specialized researcher agent, so that I can get comprehensive answers backed by research.

### Flow
1. **Setup**:
   - Tenant `acme-corp` has two agents registered:
     - `assistant` - general-purpose agent
     - `researcher` - specialized research agent
   - Both agents are connected via WebSocket
   - Client has valid JWT for tenant `acme-corp`

2. **Client → Assistant**:
   - Client sends request to `assistant` agent
   - Request type: `query` or `task`
   - Example: "What are the latest developments in quantum computing?"

3. **Assistant → Researcher** (A2A):
   - Assistant recognizes need for research
   - Sends A2A request to `researcher` agent
   - Request routed through relay's internal routing
   - Message queued if researcher temporarily offline

4. **Researcher → Assistant** (A2A response):
   - Researcher processes request, gathers information
   - Sends response back to `assistant`
   - Response includes findings/citations

5. **Assistant → Client**:
   - Assistant synthesizes final response
   - Sends back to original client
   - Client receives comprehensive answer

### Critical Components Exercised
- Multi-tenant routing
- Agent-to-agent messaging
- WebSocket connection handling for multiple agents
- Message queueing/delivery guarantees
- JWT authentication for both clients and agents
- Request/response correlation

### Validation Points
- [ ] Both agents can connect simultaneously
- [ ] Client request correctly routed to assistant
- [ ] A2A message routed from assistant to researcher
- [ ] Response path works in reverse
- [ ] Client receives final response
- [ ] Offline agent messages are queued and delivered on reconnect

### Manual Test Setup
```bash
# Terminal 1: Start relay
cd relay-elixir
mix phx.server

# Terminal 2: Start assistant agent
# (connect WebSocket with agent:acme-corp:assistant JWT)

# Terminal 3: Start researcher agent  
# (connect WebSocket with agent:acme-corp:researcher JWT)

# Terminal 4: Send client request
# (WebSocket or HTTP with client JWT)
```

### Future Work
- Automate this flow as an integration test when test infrastructure is more stable
- Consider creating a test harness that can simulate agent behavior
- Add observability/tracing to make debugging easier

---

## Additional CUJs

### Cross-Tenant Isolation
**Status**: Should be covered by unit tests

Verify that Agent A in tenant X cannot access messages or agents in tenant Y.

### Offline Message Delivery
**Status**: Partially covered by mailbox tests

Verify messages are queued when agent offline and delivered on reconnect.

### Connection Resilience
**Status**: Manual validation only

Agent disconnects and reconnects, resumes message flow without loss.

---

## Contributing

When removing a .broken e2e test:
1. Extract the scenario description to this file
2. Document what was being tested
3. Note why the test was removed (brittle, flaky, superseded, etc.)
4. Suggest future automation approach if applicable
