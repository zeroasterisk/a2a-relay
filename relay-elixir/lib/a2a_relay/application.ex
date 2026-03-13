defmodule A2aRelay.Application do
  @moduledoc """
  OTP Application for the A2A Relay.

  Starts the supervision tree:
  - AgentRegistry (ETS-backed agent presence)
  - RequestRouter (pending request tracking)
  - Mailbox (offline message queue)
  - Cleanup (periodic purge of expired data)
  - Bandit (HTTP + WebSocket server)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      A2aRelay.TenantManager,
      A2aRelay.AgentRegistry,
      A2aRelay.RequestRouter,
      A2aRelay.StreamingRouter,
      A2aRelay.Mailbox,
      A2aRelay.Cleanup,
      {Bandit, plug: A2aRelay.Router, port: A2aRelay.Config.port()}
    ]

    opts = [strategy: :one_for_one, name: A2aRelay.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
