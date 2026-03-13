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
    test "returns detailed status" do
      conn =
        conn(:get, "/status")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert Map.has_key?(body, "agents_connected")
      assert Map.has_key?(body, "pending_requests")
      assert body["version"] == "0.1.0"
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
