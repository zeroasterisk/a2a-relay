defmodule A2aRelay.RequestRouter do
  @moduledoc """
  Routes JSON-RPC requests to connected agents and tracks pending responses.

  When a client sends a request for a connected agent, the RequestRouter:
  1. Creates a pending request entry with a unique ID
  2. Sends the request to the agent's WebSocket process
  3. Waits for the response (with timeout)
  4. Returns the result to the caller

  Agents call `handle_response/2` when they receive a response from the
  downstream agent, which resolves the waiting caller.
  """

  use GenServer

  require Logger

  @table :pending_requests

  @type pending_request :: %{
          from: {pid(), reference()},
          tenant_id: String.t(),
          agent_id: String.t(),
          method: String.t(),
          timeout_at: integer()
        }

  # Client API

  @doc "Starts the RequestRouter."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Routes a request to a connected agent and waits for the response.

  Returns `{:ok, result}` if the agent responds within the timeout,
  or `{:error, reason}` on timeout or if the agent is not connected.
  """
  @spec route_request(String.t(), String.t(), String.t(), map(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def route_request(tenant_id, agent_id, method, params, timeout_ms \\ 30_000) do
    case A2aRelay.AgentRegistry.lookup(tenant_id, agent_id) do
      {:ok, %{pid: pid}} ->
        request_id = generate_request_id()

        request = %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" => params
        }

        # Register the pending request before sending
        GenServer.call(__MODULE__, {:register_request, request_id, tenant_id, agent_id, method})

        # Send request to agent's WebSocket handler
        send(pid, {:forward_request, request})

        # Wait for the response
        receive do
          {:request_response, ^request_id, response} ->
            GenServer.cast(__MODULE__, {:cleanup_request, request_id})
            {:ok, response}
        after
          timeout_ms ->
            GenServer.cast(__MODULE__, {:cleanup_request, request_id})
            {:error, :timeout}
        end

      :error ->
        {:error, :agent_not_connected}
    end
  end

  @doc """
  Called by the WebSocket handler when an agent sends a response.

  Resolves the waiting caller for the given request ID.
  """
  @spec handle_response(String.t(), map()) :: :ok | {:error, :not_found}
  def handle_response(request_id, response) do
    GenServer.call(__MODULE__, {:handle_response, request_id, response})
  end

  @doc "Returns the number of pending requests."
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    :ets.info(@table, :size)
  end

  @doc "Purges pending requests that have expired."
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    GenServer.call(__MODULE__, :purge_expired)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register_request, request_id, tenant_id, agent_id, method}, {pid, _ref}, state) do
    now = System.monotonic_time(:millisecond)
    timeout_ms = A2aRelay.Config.request_timeout_ms()

    entry = %{
      from: pid,
      tenant_id: tenant_id,
      agent_id: agent_id,
      method: method,
      timeout_at: now + timeout_ms
    }

    :ets.insert(@table, {request_id, entry})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:handle_response, request_id, response}, _from, state) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, %{from: pid}}] ->
        send(pid, {:request_response, request_id, response})
        :ets.delete(@table, request_id)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:purge_expired, _from, state) do
    now = System.monotonic_time(:millisecond)

    expired =
      :ets.foldl(
        fn {request_id, %{timeout_at: timeout_at}}, acc ->
          if timeout_at < now, do: [request_id | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(expired, &:ets.delete(@table, &1))
    {:reply, length(expired), state}
  end

  @impl true
  def handle_cast({:cleanup_request, request_id}, state) do
    :ets.delete(@table, request_id)
    {:noreply, state}
  end

  # Private helpers

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
