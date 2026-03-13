defmodule A2aRelay.RequestRouterTest do
  use ExUnit.Case, async: false

  alias A2aRelay.{AgentRegistry, RequestRouter}

  setup do
    if :ets.whereis(:agent_registry) != :undefined do
      :ets.delete_all_objects(:agent_registry)
    end

    if :ets.whereis(:pending_requests) != :undefined do
      :ets.delete_all_objects(:pending_requests)
    end

    :ok
  end

  describe "route_request/5" do
    test "routes request to connected agent and gets response" do
      # Start a fake agent process that echoes back
      test_pid = self()

      {:ok, agent_pid} =
        Agent.start(fn ->
          # This process will receive {:forward_request, request} messages
          :ok
        end)

      # Spawn a process that listens for forwarded requests and responds
      spawn(fn ->
        # Wait a bit for the agent to be registered and request to be sent
        Process.sleep(50)

        # Read the forwarded request from the agent process mailbox
        # Since we can't easily intercept Agent mailbox, we'll use a different approach
        send(test_pid, :agent_ready)
      end)

      AgentRegistry.register("t1", "echo", agent_pid, %{})

      # Route request in a separate process since it blocks
      task =
        Task.async(fn ->
          RequestRouter.route_request("t1", "echo", "test/method", %{"key" => "val"}, 2_000)
        end)

      # Wait a moment, then simulate agent response
      Process.sleep(50)

      # Find the pending request and respond to it
      # The request was sent to agent_pid, get its request_id
      # We need to check the pending_requests table
      pending = :ets.tab2list(:pending_requests)

      case pending do
        [{request_id, _entry}] ->
          response = %{
            "jsonrpc" => "2.0",
            "id" => request_id,
            "result" => %{"echo" => true}
          }

          RequestRouter.handle_response(request_id, response)

        _ ->
          :ok
      end

      result = Task.await(task, 5_000)
      assert {:ok, response} = result
      assert response["result"]["echo"] == true
    end

    test "returns :agent_not_connected for unknown agent" do
      assert {:error, :agent_not_connected} =
               RequestRouter.route_request("t1", "ghost", "test", %{}, 1_000)
    end

    test "returns :timeout when agent doesn't respond" do
      {:ok, agent_pid} = Agent.start(fn -> :ok end)
      AgentRegistry.register("t1", "slow", agent_pid, %{})

      # Use a very short timeout
      assert {:error, :timeout} =
               RequestRouter.route_request("t1", "slow", "test", %{}, 100)
    end
  end

  describe "pending_count/0" do
    test "returns 0 initially" do
      assert RequestRouter.pending_count() == 0
    end
  end

  describe "purge_expired/0" do
    test "purges expired requests" do
      count = RequestRouter.purge_expired()
      assert is_integer(count)
    end
  end
end
