defmodule A2aRelay.AgentRegistryTest do
  use ExUnit.Case, async: false

  alias A2aRelay.AgentRegistry

  setup do
    # Clean ETS table between tests
    if :ets.whereis(:agent_registry) != :undefined do
      :ets.delete_all_objects(:agent_registry)
    end

    :ok
  end

  describe "register/4 and lookup/2" do
    test "registers and looks up an agent" do
      card = %{"name" => "Test Agent"}
      assert :ok = AgentRegistry.register("tenant1", "agent1", self(), card)
      assert {:ok, entry} = AgentRegistry.lookup("tenant1", "agent1")
      assert entry.pid == self()
      assert entry.agent_card == card
      assert %DateTime{} = entry.connected_at
    end

    test "returns :error for unknown agent" do
      assert :error = AgentRegistry.lookup("tenant1", "nonexistent")
    end

    test "replaces existing registration" do
      card1 = %{"name" => "V1"}
      card2 = %{"name" => "V2"}

      AgentRegistry.register("t1", "a1", self(), card1)
      AgentRegistry.register("t1", "a1", self(), card2)

      {:ok, entry} = AgentRegistry.lookup("t1", "a1")
      assert entry.agent_card == card2
    end
  end

  describe "unregister/2" do
    test "removes an agent" do
      AgentRegistry.register("t1", "a1", self(), %{})
      assert :ok = AgentRegistry.unregister("t1", "a1")
      assert :error = AgentRegistry.lookup("t1", "a1")
    end

    test "unregistering non-existent agent is a no-op" do
      assert :ok = AgentRegistry.unregister("t1", "nonexistent")
    end
  end

  describe "list_agents/1" do
    test "lists agents for a tenant" do
      AgentRegistry.register("t1", "a1", self(), %{"name" => "Agent 1"})
      AgentRegistry.register("t1", "a2", self(), %{"name" => "Agent 2"})
      AgentRegistry.register("t2", "a3", self(), %{"name" => "Other Tenant"})

      agents = AgentRegistry.list_agents("t1")
      names = Enum.map(agents, & &1["name"]) |> Enum.sort()
      assert names == ["Agent 1", "Agent 2"]
    end

    test "returns empty list for tenant with no agents" do
      assert [] = AgentRegistry.list_agents("empty-tenant")
    end
  end

  describe "connected_count/0" do
    test "returns total connected agents" do
      initial = AgentRegistry.connected_count()
      AgentRegistry.register("t1", "a1", self(), %{})
      AgentRegistry.register("t2", "a2", self(), %{})

      assert AgentRegistry.connected_count() == initial + 2
    end
  end

  describe "process monitoring" do
    test "auto-deregisters when monitored process dies" do
      {:ok, pid} = Agent.start(fn -> :ok end)
      AgentRegistry.register("t1", "a1", pid, %{})
      assert {:ok, _} = AgentRegistry.lookup("t1", "a1")

      Agent.stop(pid)
      # Give GenServer time to handle the :DOWN message
      Process.sleep(50)

      assert :error = AgentRegistry.lookup("t1", "a1")
    end
  end

  describe "list_agents_with_meta/1" do
    test "returns full entries with agent IDs" do
      AgentRegistry.register("t1", "a1", self(), %{"name" => "Agent 1"})
      AgentRegistry.register("t1", "a2", self(), %{"name" => "Agent 2"})
      AgentRegistry.register("t2", "a3", self(), %{"name" => "Other"})

      entries = AgentRegistry.list_agents_with_meta("t1")
      assert length(entries) == 2

      ids = Enum.map(entries, fn {agent_id, _entry} -> agent_id end) |> Enum.sort()
      assert ids == ["a1", "a2"]

      {_id, entry} = Enum.find(entries, fn {id, _} -> id == "a1" end)
      assert entry.agent_card == %{"name" => "Agent 1"}
      assert entry.pid == self()
      assert %DateTime{} = entry.connected_at
    end

    test "returns empty list for tenant with no agents" do
      assert [] = AgentRegistry.list_agents_with_meta("empty")
    end
  end

  describe "presence subscriptions" do
    test "subscribe receives :connected event on register" do
      AgentRegistry.subscribe("t1")

      {:ok, pid} = Agent.start(fn -> :ok end)
      AgentRegistry.register("t1", "a1", pid, %{})

      assert_receive {:agent_presence, "t1", "a1", :connected}, 500
    end

    test "subscribe receives :disconnected event on unregister" do
      AgentRegistry.subscribe("t1")

      AgentRegistry.register("t1", "a1", self(), %{})
      assert_receive {:agent_presence, "t1", "a1", :connected}, 500

      AgentRegistry.unregister("t1", "a1")
      assert_receive {:agent_presence, "t1", "a1", :disconnected}, 500
    end

    test "subscribe receives :disconnected on process death" do
      AgentRegistry.subscribe("t1")

      {:ok, pid} = Agent.start(fn -> :ok end)
      AgentRegistry.register("t1", "a1", pid, %{})
      assert_receive {:agent_presence, "t1", "a1", :connected}, 500

      Agent.stop(pid)
      assert_receive {:agent_presence, "t1", "a1", :disconnected}, 500
    end

    test "does not receive events for other tenants" do
      AgentRegistry.subscribe("t1")
      AgentRegistry.register("t2", "a1", self(), %{})

      refute_receive {:agent_presence, _, _, _}, 100
    end

    test "unsubscribe stops events" do
      AgentRegistry.subscribe("t1")
      AgentRegistry.unsubscribe("t1")

      AgentRegistry.register("t1", "a1", self(), %{})
      refute_receive {:agent_presence, _, _, _}, 100
    end
  end
end
