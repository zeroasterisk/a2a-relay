defmodule A2aRelay.AgentRegistry do
  @moduledoc """
  Agent presence registry backed by ETS.

  Tracks connected agents by `{tenant_id, agent_id}` with their WebSocket
  handler PID, agent card, and connection metadata. Monitors agent processes
  to automatically deregister on disconnect.
  """

  use GenServer

  require Logger

  @table :agent_registry

  @type agent_entry :: %{
          pid: pid(),
          agent_card: map(),
          connected_at: DateTime.t(),
          last_ping: DateTime.t()
        }

  # Client API

  @doc "Starts the AgentRegistry."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers an agent in the registry.

  If an agent with the same `{tenant_id, agent_id}` is already registered,
  the old entry is replaced and the old process is not affected (it should
  be terminated separately).
  """
  @spec register(String.t(), String.t(), pid(), map()) :: :ok
  def register(tenant_id, agent_id, pid, agent_card) do
    GenServer.call(__MODULE__, {:register, tenant_id, agent_id, pid, agent_card})
  end

  @doc "Removes an agent from the registry."
  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(tenant_id, agent_id) do
    GenServer.call(__MODULE__, {:unregister, tenant_id, agent_id})
  end

  @doc """
  Looks up an agent by tenant and agent ID.

  Returns `{:ok, agent_entry}` if found, `:error` otherwise.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, agent_entry()} | :error
  def lookup(tenant_id, agent_id) do
    case :ets.lookup(@table, {tenant_id, agent_id}) do
      [{_key, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  @doc "Lists all agent cards for a given tenant."
  @spec list_agents(String.t()) :: [map()]
  def list_agents(tenant_id) do
    @table
    |> :ets.select([{{{tenant_id, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.map(& &1.agent_card)
  end

  @doc "Returns the total number of connected agents."
  @spec connected_count() :: non_neg_integer()
  def connected_count do
    :ets.info(@table, :size)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, monitors: %{}}}
  end

  @impl true
  def handle_call({:register, tenant_id, agent_id, pid, agent_card}, _from, state) do
    key = {tenant_id, agent_id}
    now = DateTime.utc_now()

    entry = %{
      pid: pid,
      agent_card: agent_card,
      connected_at: now,
      last_ping: now
    }

    # Demonitor old process if replacing
    state = maybe_demonitor(state, key)

    # Monitor new process
    ref = Process.monitor(pid)
    :ets.insert(@table, {key, entry})

    monitors = Map.put(state.monitors, ref, key)
    Logger.info("Agent registered: #{tenant_id}/#{agent_id} (pid: #{inspect(pid)})")

    {:reply, :ok, %{state | monitors: monitors}}
  end

  @impl true
  def handle_call({:unregister, tenant_id, agent_id}, _from, state) do
    key = {tenant_id, agent_id}
    :ets.delete(@table, key)
    state = maybe_demonitor(state, key)
    Logger.info("Agent unregistered: #{tenant_id}/#{agent_id}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{tenant_id, agent_id}, monitors} ->
        :ets.delete(@table, {tenant_id, agent_id})
        Logger.info("Agent disconnected (process down): #{tenant_id}/#{agent_id}")
        {:noreply, %{state | monitors: monitors}}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  # Private helpers

  defp maybe_demonitor(state, key) do
    case Enum.find(state.monitors, fn {_ref, k} -> k == key end) do
      {ref, _key} ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: Map.delete(state.monitors, ref)}

      nil ->
        state
    end
  end
end
