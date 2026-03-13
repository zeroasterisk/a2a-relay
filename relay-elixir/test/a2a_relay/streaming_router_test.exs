defmodule A2aRelay.StreamingRouterTest do
  use ExUnit.Case, async: false

  alias A2aRelay.StreamingRouter

  setup do
    if :ets.whereis(:streaming_requests) != :undefined do
      :ets.delete_all_objects(:streaming_requests)
    end

    :ok
  end

  describe "register/2 and route_event/3" do
    test "routes stream_chunk to registered caller" do
      request_id = "req-#{System.unique_integer([:positive])}"
      StreamingRouter.register(request_id, self())

      data = %{"type" => "stream_chunk", "content" => "hello"}
      assert :ok = StreamingRouter.route_event(request_id, "stream_chunk", data)

      assert_receive {:stream_event, "stream_chunk", ^data}
    end

    test "routes stream_end to registered caller" do
      request_id = "req-#{System.unique_integer([:positive])}"
      StreamingRouter.register(request_id, self())

      data = %{"type" => "stream_end"}
      assert :ok = StreamingRouter.route_event(request_id, "stream_end", data)

      assert_receive {:stream_event, "stream_end", ^data}
    end

    test "routes stream_error to registered caller" do
      request_id = "req-#{System.unique_integer([:positive])}"
      StreamingRouter.register(request_id, self())

      data = %{"type" => "stream_error", "error" => "something broke"}
      assert :ok = StreamingRouter.route_event(request_id, "stream_error", data)

      assert_receive {:stream_event, "stream_error", ^data}
    end

    test "returns error when no caller registered" do
      assert {:error, :not_found} =
               StreamingRouter.route_event("nonexistent", "stream_chunk", %{})
    end
  end

  describe "unregister/1" do
    test "removes a registered caller" do
      request_id = "req-#{System.unique_integer([:positive])}"
      StreamingRouter.register(request_id, self())

      assert :ok = StreamingRouter.route_event(request_id, "stream_chunk", %{})
      assert_receive {:stream_event, _, _}

      StreamingRouter.unregister(request_id)
      # Give the cast time to process
      Process.sleep(10)

      assert {:error, :not_found} =
               StreamingRouter.route_event(request_id, "stream_chunk", %{})
    end
  end

  describe "active_count/0" do
    test "tracks active streaming requests" do
      initial = StreamingRouter.active_count()

      r1 = "req-#{System.unique_integer([:positive])}"
      r2 = "req-#{System.unique_integer([:positive])}"

      StreamingRouter.register(r1, self())
      StreamingRouter.register(r2, self())

      assert StreamingRouter.active_count() == initial + 2

      StreamingRouter.unregister(r1)
      Process.sleep(10)

      assert StreamingRouter.active_count() == initial + 1
    end
  end

  describe "auto-cleanup on caller death" do
    test "cleans up when registered process dies" do
      request_id = "req-#{System.unique_integer([:positive])}"

      # Spawn a process, register it, then kill it
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      StreamingRouter.register(request_id, pid)
      assert StreamingRouter.active_count() >= 1

      send(pid, :stop)
      # Wait for DOWN message to be processed
      Process.sleep(50)

      assert {:error, :not_found} =
               StreamingRouter.route_event(request_id, "stream_chunk", %{})
    end
  end
end
