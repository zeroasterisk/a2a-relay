defmodule A2aRelay.Config do
  @moduledoc """
  Configuration reader for the A2A Relay.

  Reads values from Application environment with sensible defaults.
  Runtime values are set via environment variables in `config/runtime.exs`.
  """

  @doc "HTTP port for Bandit to listen on."
  @spec port() :: non_neg_integer()
  def port, do: Application.get_env(:a2a_relay, :port, 8080)

  @doc "Shared secret for JWT validation (HMAC/HS256)."
  @spec jwt_secret() :: String.t()
  def jwt_secret, do: Application.get_env(:a2a_relay, :jwt_secret, "dev-secret-change-me")

  @doc "Timeout in ms for agent auth after WebSocket connect."
  @spec auth_timeout_ms() :: non_neg_integer()
  def auth_timeout_ms, do: Application.get_env(:a2a_relay, :auth_timeout_ms, 30_000)

  @doc "Timeout in ms for request routing to agents."
  @spec request_timeout_ms() :: non_neg_integer()
  def request_timeout_ms, do: Application.get_env(:a2a_relay, :request_timeout_ms, 30_000)

  @doc "Maximum queued messages per agent in the mailbox."
  @spec max_mailbox_messages() :: non_neg_integer()
  def max_mailbox_messages, do: Application.get_env(:a2a_relay, :max_mailbox_messages, 999)

  @doc "Time-to-live for mailbox messages in hours."
  @spec message_ttl_hours() :: non_neg_integer()
  def message_ttl_hours, do: Application.get_env(:a2a_relay, :message_ttl_hours, 216)

  @doc "Interval in ms between cleanup runs."
  @spec cleanup_interval_ms() :: non_neg_integer()
  def cleanup_interval_ms, do: Application.get_env(:a2a_relay, :cleanup_interval_ms, 3_600_000)

  @doc "Interval in ms between WebSocket ping frames."
  @spec ws_ping_interval_ms() :: non_neg_integer()
  def ws_ping_interval_ms, do: Application.get_env(:a2a_relay, :ws_ping_interval_ms, 20_000)

  @doc "Admin API key for protected endpoints. `nil` means admin endpoints are open."
  @spec admin_key() :: String.t() | nil
  def admin_key, do: Application.get_env(:a2a_relay, :admin_key, nil)

  @doc "Whether JWT authentication is required for client requests."
  @spec auth_required() :: boolean()
  def auth_required, do: Application.get_env(:a2a_relay, :auth_required, true)
end
