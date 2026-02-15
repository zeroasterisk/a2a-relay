# A2A Relay - Elixir Implementation

Phoenix/Elixir implementation of the A2A relay.

## Status: Placeholder

This implementation is planned but not yet started. See `relay-go/` for the active implementation.

## Why Elixir?

- Perfect process model for concurrent agent connections
- Phoenix Channels for WebSocket handling
- Built-in PubSub (no Redis needed)
- Fault tolerance via OTP supervisors
- Battle-tested for real-time messaging (WhatsApp, Discord)

## Planned Features

- Phoenix Channels for agent WebSocket connections
- Phoenix.Presence for agent tracking
- GenServer for request/response coordination
- Mnesia or Postgres for optional persistence

## Future Implementation

```elixir
# Agent connects via Phoenix Channel
defmodule A2ARelay.AgentChannel do
  use Phoenix.Channel
  
  def join("agent:" <> agent_id, params, socket) do
    # Auth, register in presence
  end
  
  def handle_in("a2a:response", payload, socket) do
    # Route response to waiting request
  end
end
```
