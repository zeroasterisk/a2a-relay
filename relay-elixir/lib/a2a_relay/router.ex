defmodule A2aRelay.Router do
  @moduledoc """
  HTTP router for the A2A Relay.

  Endpoints:
  - `GET /health` — Health check
  - `GET /status` — Detailed relay status
  - `GET /ws/agent` — WebSocket upgrade for agent connections
  - `GET /admin/tenants` — List all tenants
  - `POST /admin/tenants` — Create a tenant
  - `GET /admin/tenants/:id` — Tenant details + connected agents
  - `DELETE /admin/tenants/:id` — Delete a tenant
  - `GET /admin/agents` — All connected agents across tenants
  - `GET /:tenant/:agent/.well-known/agent.json` — Agent card discovery
  - `POST /:tenant/:agent/` — JSON-RPC dispatch to connected agents
  """

  use Plug.Router

  require Logger

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
    tenants = length(A2aRelay.TenantManager.list())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "status" => "ok",
        "agents_connected" => count,
        "pending_requests" => pending,
        "tenants" => tenants,
        "version" => "0.2.0"
      })
    )
  end

  # WebSocket upgrade for agents
  get "/ws/agent" do
    conn
    |> WebSockAdapter.upgrade(A2aRelay.WebSocket.Handler, [], timeout: 60_000)
    |> halt()
  end

  # --- Admin endpoints ---

  get "/admin/tenants" do
    with :ok <- authenticate_admin(conn) do
      tenants =
        A2aRelay.TenantManager.list()
        |> Enum.map(&tenant_to_json/1)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"tenants" => tenants}))
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
    end
  end

  post "/admin/tenants" do
    with :ok <- authenticate_admin(conn) do
      body = conn.body_params

      tenant_id = Map.get(body, "id")
      name = Map.get(body, "name", tenant_id)
      jwt_secret = Map.get(body, "jwt_secret")

      cond do
        is_nil(tenant_id) or tenant_id == "" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{"error" => "id is required"}))

        true ->
          opts = [name: name]
          opts = if jwt_secret, do: Keyword.put(opts, :jwt_secret, jwt_secret), else: opts

          case A2aRelay.TenantManager.register(tenant_id, opts) do
            :ok ->
              {:ok, tenant} = A2aRelay.TenantManager.lookup(tenant_id)

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(201, Jason.encode!(%{"tenant" => tenant_to_json(tenant)}))

            {:error, :already_exists} ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(409, Jason.encode!(%{"error" => "tenant already exists"}))
          end
      end
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
    end
  end

  get "/admin/tenants/:id" do
    with :ok <- authenticate_admin(conn) do
      tenant_id = conn.path_params["id"]

      case A2aRelay.TenantManager.lookup(tenant_id) do
        {:ok, tenant} ->
          agents =
            A2aRelay.AgentRegistry.list_agents_with_meta(tenant_id)
            |> Enum.map(fn {agent_id, entry} ->
              %{
                "agent_id" => agent_id,
                "agent_card" => entry.agent_card,
                "connected_at" => DateTime.to_iso8601(entry.connected_at)
              }
            end)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "tenant" => tenant_to_json(tenant),
              "agents" => agents
            })
          )

        :error ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, Jason.encode!(%{"error" => "tenant not found"}))
      end
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
    end
  end

  delete "/admin/tenants/:id" do
    with :ok <- authenticate_admin(conn) do
      tenant_id = conn.path_params["id"]

      case A2aRelay.TenantManager.lookup(tenant_id) do
        {:ok, _tenant} ->
          A2aRelay.TenantManager.delete(tenant_id)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"deleted" => tenant_id}))

        :error ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, Jason.encode!(%{"error" => "tenant not found"}))
      end
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
    end
  end

  get "/admin/agents" do
    with :ok <- authenticate_admin(conn) do
      tenants = A2aRelay.TenantManager.list()

      all_agents =
        Enum.flat_map(tenants, fn tenant ->
          A2aRelay.AgentRegistry.list_agents_with_meta(tenant.id)
          |> Enum.map(fn {agent_id, entry} ->
            %{
              "tenant_id" => tenant.id,
              "agent_id" => agent_id,
              "agent_card" => entry.agent_card,
              "connected_at" => DateTime.to_iso8601(entry.connected_at)
            }
          end)
        end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"agents" => all_agents}))
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
    end
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

  # SSE streaming endpoint
  post "/:tenant/:agent/message/stream" do
    tenant = conn.path_params["tenant"]
    agent = conn.path_params["agent"]

    with {:ok, _client} <- authenticate_client(conn),
         {:ok, method, params, _id} <- extract_jsonrpc(conn.body_params) do
      case A2aRelay.AgentRegistry.lookup(tenant, agent) do
        {:ok, %{pid: ws_pid}} ->
          request_id = generate_request_id()

          request = %{
            "jsonrpc" => "2.0",
            "id" => request_id,
            "method" => method,
            "params" => params,
            "streaming" => true
          }

          # Register this process for streaming events
          A2aRelay.StreamingRouter.register(request_id, self())

          # Forward streaming request to agent
          send(ws_pid, {:forward_request, request})

          # Start chunked SSE response
          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> put_resp_header("cache-control", "no-cache")
            |> put_resp_header("connection", "keep-alive")
            |> send_chunked(200)

          # Enter the SSE event loop
          timeout_ms = A2aRelay.Config.request_timeout_ms()
          result = stream_sse_loop(conn, request_id, timeout_ms)
          A2aRelay.StreamingRouter.unregister(request_id)
          result

        :error ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            404,
            Jason.encode!(%{"error" => "agent not connected"})
          )
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

  defp authenticate_admin(conn) do
    case A2aRelay.Config.admin_key() do
      nil ->
        # No admin key configured — open access
        :ok

      expected_key ->
        case get_req_header(conn, "x-admin-key") do
          [^expected_key] -> :ok
          _ -> {:error, :unauthorized}
        end
    end
  end

  defp authenticate_client(conn) do
    if not A2aRelay.Config.auth_required() do
      {:ok, %{tenant: "anonymous", user_id: "anonymous"}}
    else
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] ->
          # Try per-tenant secret first, then global fallback
          tenant_id = conn.path_params["tenant"]
          tenant_secret = A2aRelay.TenantManager.jwt_secret(tenant_id)
          global_secret = A2aRelay.Config.jwt_secret()

          secrets =
            if tenant_secret do
              [tenant_secret, global_secret]
            else
              [global_secret]
            end

          try_secrets(token, secrets)

        _ ->
          {:error, :unauthorized}
      end
    end
  end

  defp try_secrets(_token, []), do: {:error, :unauthorized}

  defp try_secrets(token, [secret | rest]) do
    case A2aRelay.Auth.validate_client_token(token, secret) do
      {:ok, client} -> {:ok, client}
      {:error, _} -> try_secrets(token, rest)
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

  defp stream_sse_loop(conn, request_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_stream_sse(conn, request_id, deadline)
  end

  defp do_stream_sse(conn, request_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      # Timeout — send error event and close
      {:ok, conn} = chunk(conn, format_sse("stream_error", %{"error" => "timeout"}))
      conn
    else
      receive do
        {:stream_event, "stream_chunk", data} ->
          case chunk(conn, format_sse("stream_chunk", data)) do
            {:ok, conn} ->
              do_stream_sse(conn, request_id, deadline)

            {:error, _reason} ->
              # Client disconnected
              conn
          end

        {:stream_event, "stream_end", data} ->
          {:ok, conn} = chunk(conn, format_sse("stream_end", data))
          conn

        {:stream_event, "stream_error", data} ->
          {:ok, conn} = chunk(conn, format_sse("stream_error", data))
          conn
      after
        min(remaining, 30_000) ->
          # Send SSE comment as keepalive
          case chunk(conn, ": keepalive\n\n") do
            {:ok, conn} ->
              do_stream_sse(conn, request_id, deadline)

            {:error, _reason} ->
              conn
          end
      end
    end
  end

  defp format_sse(event_type, data) do
    json = Jason.encode!(data)
    "event: #{event_type}\ndata: #{json}\n\n"
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp tenant_to_json(tenant) do
    %{
      "id" => tenant.id,
      "name" => tenant.name,
      "enabled" => tenant.enabled,
      "created_at" => DateTime.to_iso8601(tenant.created_at)
    }
  end
end
