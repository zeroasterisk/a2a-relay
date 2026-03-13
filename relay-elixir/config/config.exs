import Config

config :a2a_relay,
  port: 8080,
  jwt_secret: "dev-secret-change-me",
  auth_timeout_ms: 30_000,
  request_timeout_ms: 30_000,
  max_mailbox_messages: 999,
  message_ttl_hours: 216,
  cleanup_interval_ms: 3_600_000,
  ws_ping_interval_ms: 20_000

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :tenant_id, :agent_id]

import_config "#{config_env()}.exs"
