defmodule A2aRelay.WebSocket.Handler do
  @moduledoc """
  WebSocket handler for agent connections.

  Implements the `WebSock` behaviour. Each connected agent gets its own
  handler process. The lifecycle:

  1. Connection opened — starts unauthenticated
  2. First message must be auth: `{"type": "auth", "token": "...", "agent_card": {...}}`
  3. JWT validated, agent registered in AgentRegistry
  4. Mailbox drained and forwarded to agent
  5. Subsequent messages are request/response forwarding
  6. On disconnect, agent is unregistered
  """

  require Logger

  @behaviour WebSock

  defstruct [:tenant_id, :agent_id, :authenticated, :ping_timer]

  @impl WebSock
  def init(_opts) do
    # Start unauthenticated — agent must send auth message first
    {:ok, %__MODULE__{authenticated: false}}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, %{authenticated: false} = state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "auth"} = msg} ->
        handle_auth(msg, state)

      {:ok, _other} ->
        error = Jason.encode!(%{"error" => "first message must be auth"})
        {:stop, :normal, [{:text, error}], state}

      {:error, _} ->
        error = Jason.encode!(%{"error" => "invalid JSON"})
        {:stop, :normal, [{:text, error}], state}
    end
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, %{authenticated: true} = state) do
    case Jason.decode(text) do
      {:ok, %{"id" => request_id} = response} ->
        # This is a response from the agent to a forwarded request
        A2aRelay.RequestRouter.handle_response(request_id, response)
        {:ok, state}

      {:ok, _other} ->
        Logger.warning("Unexpected message from agent #{state.tenant_id}/#{state.agent_id}")
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  @impl WebSock
  def handle_in({_data, [opcode: :binary]}, state) do
    # Ignore binary frames
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:forward_request, request}, state) do
    # Forward a JSON-RPC request to the connected agent
    {:push, {:text, Jason.encode!(request)}, state}
  end

  @impl WebSock
  def handle_info(:send_ping, state) do
    schedule_ping(state)
    {:push, {:ping, ""}, state}
  end

  @impl WebSock
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl WebSock
  def terminate(_reason, %{authenticated: true} = state) do
    A2aRelay.AgentRegistry.unregister(state.tenant_id, state.agent_id)

    Logger.info(
      "Agent WebSocket disconnected: #{state.tenant_id}/#{state.agent_id}"
    )

    :ok
  end

  @impl WebSock
  def terminate(_reason, _state) do
    :ok
  end

  # Private helpers

  defp handle_auth(%{"token" => token} = msg, state) do
    secret = A2aRelay.Config.jwt_secret()

    case A2aRelay.Auth.validate_agent_token(token, secret) do
      {:ok, %{tenant: tenant_id, agent_id: agent_id}} ->
        agent_card = Map.get(msg, "agent_card", %{})

        A2aRelay.AgentRegistry.register(tenant_id, agent_id, self(), agent_card)

        Logger.info("Agent authenticated: #{tenant_id}/#{agent_id}")

        # Drain mailbox and forward queued messages
        messages = A2aRelay.Mailbox.drain(tenant_id, agent_id)

        queued_frames =
          Enum.map(messages, fn msg ->
            request = %{
              "jsonrpc" => "2.0",
              "id" => msg.id,
              "method" => msg.method,
              "params" => msg.params
            }

            {:text, Jason.encode!(request)}
          end)

        # Send auth success
        auth_ok = {:text, Jason.encode!(%{"type" => "auth_success"})}

        state = %{
          state
          | authenticated: true,
            tenant_id: tenant_id,
            agent_id: agent_id
        }

        # Schedule ping
        schedule_ping(state)

        {:push, [auth_ok | queued_frames], state}

      {:error, reason} ->
        Logger.warning("Agent auth failed: #{inspect(reason)}")
        error = Jason.encode!(%{"error" => "authentication failed", "reason" => inspect(reason)})
        {:stop, :normal, [{:text, error}], state}
    end
  end

  defp handle_auth(_msg, state) do
    error = Jason.encode!(%{"error" => "auth message must include token"})
    {:stop, :normal, [{:text, error}], state}
  end

  defp schedule_ping(state) do
    interval = A2aRelay.Config.ws_ping_interval_ms()
    timer = Process.send_after(self(), :send_ping, interval)
    %{state | ping_timer: timer}
  end
end
