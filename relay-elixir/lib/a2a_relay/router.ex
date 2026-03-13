defmodule A2aRelay.Router do
  @moduledoc """
  HTTP router for the A2A Relay.

  Endpoints:
  - `GET /health` — Health check
  - `GET /status` — Detailed relay status
  - `GET /ws/agent` — WebSocket upgrade for agent connections
  - `GET /:tenant/:agent/.well-known/agent.json` — Agent card discovery
  - `POST /:tenant/:agent/` — JSON-RPC dispatch to connected agents
  """

  use Plug.Router

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  # Health check — no auth required
  get "/health" do
    count = A2aRelay.AgentRegistry.connected_count()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"status" => "ok", "agents_connected" => count}))
  end

  # Status — no auth required (for monitoring)
  get "/status" do
    count = A2aRelay.AgentRegistry.connected_count()
    pending = A2aRelay.RequestRouter.pending_count()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "status" => "ok",
        "agents_connected" => count,
        "pending_requests" => pending,
        "version" => "0.1.0"
      })
    )
  end

  # WebSocket upgrade for agents
  get "/ws/agent" do
    conn
    |> WebSockAdapter.upgrade(A2aRelay.WebSocket.Handler, [], timeout: 60_000)
    |> halt()
  end

  # Agent card discovery
  get "/:tenant/:agent/.well-known/agent.json" do
    tenant = conn.path_params["tenant"]
    agent = conn.path_params["agent"]

    case A2aRelay.AgentRegistry.lookup(tenant, agent) do
      {:ok, %{agent_card: agent_card}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(agent_card))

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "agent not found"}))
    end
  end

  # JSON-RPC dispatch
  post "/:tenant/:agent/" do
    tenant = conn.path_params["tenant"]
    agent = conn.path_params["agent"]

    with {:ok, _client} <- authenticate_client(conn),
         {:ok, method, params, id} <- extract_jsonrpc(conn.body_params) do
      timeout_ms = A2aRelay.Config.request_timeout_ms()

      case A2aRelay.RequestRouter.route_request(tenant, agent, method, params, timeout_ms) do
        {:ok, response} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(response))

        {:error, :agent_not_connected} ->
          # Queue in mailbox for later delivery
          case A2aRelay.Mailbox.enqueue(tenant, agent, method, params) do
            :ok ->
              submitted = %{
                "jsonrpc" => "2.0",
                "id" => id,
                "result" => %{
                  "status" => "submitted",
                  "message" => "Agent is offline. Message queued for delivery."
                }
              }

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(202, Jason.encode!(submitted))

            {:error, :mailbox_full} ->
              error_response(conn, id, -32_000, "Agent mailbox is full")
          end

        {:error, :timeout} ->
          error_response(conn, id, -32_000, "Request timed out")
      end
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))

      {:error, :invalid_jsonrpc} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "error" => %{"code" => -32_600, "message" => "Invalid JSON-RPC request"}
          })
        )
    end
  end

  # Catch-all
  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not found"}))
  end

  # Private helpers

  defp authenticate_client(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        secret = A2aRelay.Config.jwt_secret()

        case A2aRelay.Auth.validate_client_token(token, secret) do
          {:ok, client} -> {:ok, client}
          {:error, _} -> {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp extract_jsonrpc(%{"jsonrpc" => "2.0", "method" => method} = body) do
    params = Map.get(body, "params", %{})
    id = Map.get(body, "id")
    {:ok, method, params, id}
  end

  defp extract_jsonrpc(_), do: {:error, :invalid_jsonrpc}

  defp error_response(conn, id, code, message) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end
end
