defmodule A2aRelay.Cleanup do
  @moduledoc """
  Periodic cleanup worker.

  Runs on a configurable interval (default: 1 hour) to purge:
  - Expired mailbox messages (older than TTL)
  - Expired pending requests
  """

  use GenServer

  require Logger

  @doc "Starts the Cleanup worker."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Logger.info("Running periodic cleanup")

    mailbox_purged = A2aRelay.Mailbox.purge_expired()
    requests_purged = A2aRelay.RequestRouter.purge_expired()

    if mailbox_purged > 0 or requests_purged > 0 do
      Logger.info(
        "Cleanup complete: #{mailbox_purged} mailbox messages, #{requests_purged} pending requests purged"
      )
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    interval = A2aRelay.Config.cleanup_interval_ms()
    Process.send_after(self(), :cleanup, interval)
  end
end
