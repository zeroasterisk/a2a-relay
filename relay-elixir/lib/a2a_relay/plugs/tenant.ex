defmodule A2aRelay.Plugs.Tenant do
  @moduledoc """
  Plug that extracts and validates the tenant from the request path.

  Passes through system routes (`/health`, `/status`, `/ws/agent`, `/admin/*`)
  unchanged. For all other routes, extracts the first path segment as the
  tenant ID, validates it via `TenantManager`, and assigns `conn.assigns.tenant_id`.

  Returns 403 JSON on unknown or disabled tenants.
  """

  @behaviour Plug

  require Logger

  @passthrough_prefixes ["health", "status", "ws", "admin"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.path_info do
      [first | _] when first in @passthrough_prefixes ->
        conn

      [tenant_id | _rest] ->
        if A2aRelay.TenantManager.enabled?(tenant_id) do
          Plug.Conn.assign(conn, :tenant_id, tenant_id)
        else
          Logger.warning("Rejected request for unknown/disabled tenant: #{tenant_id}")

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => "tenant not found or disabled"}))
          |> Plug.Conn.halt()
        end

      _ ->
        conn
    end
  end
end
