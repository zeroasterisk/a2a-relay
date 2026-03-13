defmodule A2aRelay.StreamingRouter do
  @moduledoc """
  Tracks and routes SSE streaming events to the correct HTTP caller process.

  When a client requests `POST /:tenant/:agent/message/stream`, the HTTP
  handler registers a `request_id → caller_pid` mapping here. As the agent
  sends `stream_chunk`, `stream_end`, or `stream_error` WebSocket messages,
  the WebSocket handler calls `route_event/3` to forward them to the waiting
  HTTP process, which writes them as SSE events on the chunked response.
  """

  use GenServer

  require Logger

  @table :streaming_requests

  # Client API

  @doc "Starts the StreamingRouter."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a streaming request, mapping `request_id` to the calling process.

  The caller process will receive `{:stream_event, type, data}` messages.
  A monitor is set up to auto-cleanup if the caller dies.
  """
  @spec register(String.t(), pid()) :: :ok
  def register(request_id, pid) do
    GenServer.call(__MODULE__, {:register, request_id, pid})
  end

  @doc """
  Unregisters a streaming request (e.g., after stream_end or timeout).
  """
  @spec unregister(String.t()) :: :ok
  def unregister(request_id) do
    GenServer.cast(__MODULE__, {:unregister, request_id})
  end

  @doc """
  Routes a streaming event to the registered caller for `request_id`.

  `event_type` is one of `"stream_chunk"`, `"stream_end"`, or `"stream_error"`.
  `data` is the event payload (map).

  Returns `:ok` if delivered, `{:error, :not_found}` if no caller is registered.
  """
  @spec route_event(String.t(), String.t(), map()) :: :ok | {:error, :not_found}
  def route_event(request_id, event_type, data) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, %{pid: pid}}] ->
        send(pid, {:stream_event, event_type, data})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Returns the number of active streaming requests."
  @spec active_count() :: non_neg_integer()
  def active_count do
    :ets.info(@table, :size)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, monitors: %{}}}
  end

  @impl true
  def handle_call({:register, request_id, pid}, _from, state) do
    ref = Process.monitor(pid)
    entry = %{pid: pid, registered_at: System.monotonic_time(:millisecond)}
    :ets.insert(@table, {request_id, entry})
    monitors = Map.put(state.monitors, ref, request_id)
    Logger.debug("StreamingRouter: registered #{request_id}")
    {:reply, :ok, %{state | monitors: monitors}}
  end

  @impl true
  def handle_cast({:unregister, request_id}, state) do
    :ets.delete(@table, request_id)

    # Find and remove monitor
    state =
      case Enum.find(state.monitors, fn {_ref, rid} -> rid == request_id end) do
        {ref, _rid} ->
          Process.demonitor(ref, [:flush])
          %{state | monitors: Map.delete(state.monitors, ref)}

        nil ->
          state
      end

    Logger.debug("StreamingRouter: unregistered #{request_id}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {request_id, monitors} when not is_nil(request_id) ->
        :ets.delete(@table, request_id)
        Logger.debug("StreamingRouter: caller died, cleaned up #{request_id}")
        {:noreply, %{state | monitors: monitors}}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end
end
