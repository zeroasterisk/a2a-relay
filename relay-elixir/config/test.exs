import Config

config :a2a_relay,
  port: 0,
  jwt_secret: "test-secret",
  cleanup_interval_ms: :timer.hours(24),
  ws_ping_interval_ms: :timer.minutes(5)

config :logger, level: :warning
