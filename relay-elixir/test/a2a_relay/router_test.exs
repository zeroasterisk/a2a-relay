defmodule A2aRelay.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias A2aRelay.{AgentRegistry, Auth, Router}

  @secret "test-secret"

  setup do
    if :ets.whereis(:agent_registry) != :undefined do
      :ets.delete_all_objects(:agent_registry)
    end

    if :ets.whereis(:mailbox) != :undefined do
      :ets.delete_all_objects(:mailbox)
    end

    # Clean tenants and re-add default
    if :ets.whereis(:tenants) != :undefined do
      :ets.delete_all_objects(:tenants)

      default = %{
        id: "default",
        name: "Default Tenant",
        jwt_secret: nil,
        created_at: DateTime.utc_now(),
        enabled: true
      }

      :ets.insert(:tenants, {"default", default})
    end

    # Ensure no admin key is set (open admin access for tests)
    Application.put_env(:a2a_relay, :admin_key, nil)

    :ok
  end

  describe "GET /health" do
    test "returns ok with agent count" do
      conn =
        conn(:get, "/health")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert is_integer(body["agents_connected"])
    end
  end

  describe "GET /status" do
    test "returns detailed status with tenants count" do
      conn =
        conn(:get, "/status")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert Map.has_key?(body, "agents_connected")
      assert Map.has_key?(body, "pending_requests")
      assert Map.has_key?(body, "tenants")
      assert body["version"] == "0.2.0"
    end
  end

  describe "GET /:tenant/:agent/.well-known/agent.json" do
    test "serves agent card when connected" do
      card = %{"name" => "Helper Bot", "url" => "https://example.com"}
      AgentRegistry.register("acme", "helper", self(), card)

      conn =
        conn(:get, "/acme/helper/.well-known/agent.json")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "Helper Bot"
    end

    test "returns 404 when agent not connected" do
      conn =
        conn(:get, "/acme/ghost/.well-known/agent.json")
        |> Router.call(Router.init([]))

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "agent not found"
    end
  end

  describe "POST /:tenant/:agent/" do
    test "returns 401 without auth" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "test", "id" => "1"})

      conn =
        conn(:post, "/acme/helper/", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 401
    end

    test "returns 401 with invalid token" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "test", "id" => "1"})

      conn =
        conn(:post, "/acme/helper/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer invalid-token")
        |> Router.call(Router.init([]))

      assert conn.status == 401
    end

    test "queues message when agent is offline (returns 202)" do
      token = make_client_token("acme", "user-1")
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "message/send", "id" => "req-1", "params" => %{}})

      conn =
        conn(:post, "/acme/offline-agent/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(Router.init([]))

      assert conn.status == 202
      resp = Jason.decode!(conn.resp_body)
      assert resp["result"]["status"] == "submitted"
    end

    test "returns 400 for invalid JSON-RPC" do
      token = make_client_token("acme", "user-1")
      body = Jason.encode!(%{"not" => "jsonrpc"})

      conn =
        conn(:post, "/acme/helper/", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(Router.init([]))

      assert conn.status == 400
    end
  end

  describe "GET /admin/tenants" do
    test "lists all tenants" do
      conn =
        conn(:get, "/admin/tenants")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["tenants"])
      assert Enum.any?(body["tenants"], &(&1["id"] == "default"))
    end

    test "returns 401 when admin key is set but not provided" do
      Application.put_env(:a2a_relay, :admin_key, "admin-secret")

      conn =
        conn(:get, "/admin/tenants")
        |> Router.call(Router.init([]))

      assert conn.status == 401
    after
      Application.put_env(:a2a_relay, :admin_key, nil)
    end

    test "returns 200 with correct admin key" do
      Application.put_env(:a2a_relay, :admin_key, "admin-secret")

      conn =
        conn(:get, "/admin/tenants")
        |> put_req_header("x-admin-key", "admin-secret")
        |> Router.call(Router.init([]))

      assert conn.status == 200
    after
      Application.put_env(:a2a_relay, :admin_key, nil)
    end
  end

  describe "POST /admin/tenants" do
    test "creates a new tenant" do
      body = Jason.encode!(%{"id" => "new-tenant", "name" => "New Tenant"})

      conn =
        conn(:post, "/admin/tenants", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 201
      resp = Jason.decode!(conn.resp_body)
      assert resp["tenant"]["id"] == "new-tenant"
      assert resp["tenant"]["name"] == "New Tenant"
    end

    test "returns 409 for duplicate tenant" do
      body = Jason.encode!(%{"id" => "default"})

      conn =
        conn(:post, "/admin/tenants", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 409
    end

    test "returns 400 when id is missing" do
      body = Jason.encode!(%{"name" => "No ID"})

      conn =
        conn(:post, "/admin/tenants", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 400
    end
  end

  describe "GET /admin/tenants/:id" do
    test "returns tenant details with connected agents" do
      card = %{"name" => "Bot"}
      AgentRegistry.register("default", "bot1", self(), card)

      conn =
        conn(:get, "/admin/tenants/default")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["tenant"]["id"] == "default"
      assert length(resp["agents"]) == 1
      assert hd(resp["agents"])["agent_id"] == "bot1"
    end

    test "returns 404 for unknown tenant" do
      conn =
        conn(:get, "/admin/tenants/nonexistent")
        |> Router.call(Router.init([]))

      assert conn.status == 404
    end
  end

  describe "DELETE /admin/tenants/:id" do
    test "deletes existing tenant" do
      A2aRelay.TenantManager.register("to-delete")

      conn =
        conn(:delete, "/admin/tenants/to-delete")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["deleted"] == "to-delete"
      assert :error = A2aRelay.TenantManager.lookup("to-delete")
    end

    test "returns 404 for unknown tenant" do
      conn =
        conn(:delete, "/admin/tenants/ghost")
        |> Router.call(Router.init([]))

      assert conn.status == 404
    end
  end

  describe "GET /admin/agents" do
    test "lists agents across all tenants" do
      A2aRelay.TenantManager.register("t1")
      AgentRegistry.register("default", "a1", self(), %{"name" => "A1"})
      AgentRegistry.register("t1", "a2", self(), %{"name" => "A2"})

      conn =
        conn(:get, "/admin/agents")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert length(resp["agents"]) == 2

      tenant_ids = Enum.map(resp["agents"], & &1["tenant_id"]) |> Enum.sort()
      assert tenant_ids == ["default", "t1"]
    end
  end

  describe "catch-all" do
    test "returns 404 for unknown routes" do
      conn =
        conn(:get, "/unknown/path")
        |> Router.call(Router.init([]))

      assert conn.status == 404
    end
  end

  # Helpers

  defp make_client_token(tenant, user_id) do
    Auth.generate_token(
      %{"role" => "client", "tenant" => tenant, "user_id" => user_id},
      @secret
    )
  end
end
