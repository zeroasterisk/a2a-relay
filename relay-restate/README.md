# A2A Relay - Restate Implementation

Restate-based implementation with durable execution.

## Status: Placeholder

This implementation is planned but not yet started. See `relay-go/` for the active implementation.

## Why Restate?

- Durable execution (survives relay restarts)
- Automatic retries with backoff
- Built-in state management
- Good for guaranteed delivery scenarios

## Planned Features

- Virtual object per agent (maintains connection state)
- Durable request queue (messages persist until delivered)
- Automatic retry on transient failures
- State snapshots for agent metadata

## Future Implementation

```typescript
import * as restate from "@restatedev/restate-sdk";

const agentService = restate.object({
  name: "agent",
  handlers: {
    async sendMessage(ctx: restate.ObjectContext, request: A2ARequest) {
      // Durable message handling
      const result = await ctx.run(() => forwardToAgent(request));
      return result;
    }
  }
});
```

## Tradeoffs vs Go Implementation

| Aspect | Restate | Go |
|--------|---------|-----|
| Durability | Messages survive restart | Lost on restart |
| Latency | +10-20ms (persistence) | <5ms |
| Complexity | Higher | Lower |
| Best for | Critical messages | Real-time chat |
