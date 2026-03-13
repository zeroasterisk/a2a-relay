defmodule A2aRelay.Mailbox do
  @moduledoc """
  Offline message queue for disconnected agents.

  When an agent is offline, incoming requests are queued in the mailbox.
  When the agent reconnects, the mailbox is drained and messages are
  forwarded to the agent.

  Messages have a configurable TTL (default 9 days) and a per-agent
  limit (default 999 messages). Expired messages are purged by the
  Cleanup worker.
  """

  use GenServer

  require Logger

  @table :mailbox

  @type message :: %{
          id: String.t(),
          method: String.t(),
          params: map(),
          queued_at: integer()
        }

  # Client API

  @doc "Starts the Mailbox."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a message for an offline agent.

  Returns `:ok` if the message was queued, or `{:error, :mailbox_full}`
  if the agent's mailbox has reached the maximum capacity.
  """
  @spec enqueue(String.t(), String.t(), String.t(), map()) :: :ok | {:error, :mailbox_full}
  def enqueue(tenant_id, agent_id, method, params) do
    GenServer.call(__MODULE__, {:enqueue, tenant_id, agent_id, method, params})
  end

  @doc """
  Drains all queued messages for an agent, returning them in FIFO order.

  Messages are removed from the mailbox after draining.
  """
  @spec drain(String.t(), String.t()) :: [message()]
  def drain(tenant_id, agent_id) do
    GenServer.call(__MODULE__, {:drain, tenant_id, agent_id})
  end

  @doc "Returns the number of queued messages for an agent."
  @spec queue_depth(String.t(), String.t()) :: non_neg_integer()
  def queue_depth(tenant_id, agent_id) do
    :ets.match(@table, {{tenant_id, agent_id, :_}, :_})
    |> length()
  end

  @doc "Purges messages older than the configured TTL. Returns count purged."
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    GenServer.call(__MODULE__, :purge_expired)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    {:ok, %{table: table, counter: 0}}
  end

  @impl true
  def handle_call({:enqueue, tenant_id, agent_id, method, params}, _from, state) do
    max = A2aRelay.Config.max_mailbox_messages()
    current_depth = queue_depth_internal(tenant_id, agent_id)

    if current_depth >= max do
      {:reply, {:error, :mailbox_full}, state}
    else
      message_id = generate_message_id()
      now = System.monotonic_time(:millisecond)
      seq = state.counter

      entry = %{
        id: message_id,
        method: method,
        params: params,
        queued_at: now
      }

      # Use {tenant, agent, seq} as key for strictly FIFO ordered insertion
      key = {tenant_id, agent_id, seq}
      :ets.insert(@table, {key, entry})

      Logger.debug("Mailbox enqueue: #{tenant_id}/#{agent_id} method=#{method}")
      {:reply, :ok, %{state | counter: seq + 1}}
    end
  end

  @impl true
  def handle_call({:drain, tenant_id, agent_id}, _from, state) do
    # Select all messages for this agent (ordered by seq due to ordered_set)
    messages =
      :ets.match_object(@table, {{tenant_id, agent_id, :_}, :_})
      |> Enum.map(fn {key, entry} ->
        :ets.delete(@table, key)
        entry
      end)

    if messages != [] do
      Logger.info("Mailbox drained: #{tenant_id}/#{agent_id} (#{length(messages)} messages)")
    end

    {:reply, messages, state}
  end

  @impl true
  def handle_call(:purge_expired, _from, state) do
    ttl_ms = A2aRelay.Config.message_ttl_hours() * 3_600_000
    cutoff = System.monotonic_time(:millisecond) - ttl_ms

    expired =
      :ets.foldl(
        fn {key, %{queued_at: queued_at}}, acc ->
          if queued_at < cutoff, do: [key | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(expired, &:ets.delete(@table, &1))
    {:reply, length(expired), state}
  end

  # Private helpers

  defp queue_depth_internal(tenant_id, agent_id) do
    :ets.match(@table, {{tenant_id, agent_id, :_}, :_})
    |> length()
  end

  defp generate_message_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
