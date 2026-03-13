import Config

if config_env() == :prod do
  config :a2a_relay,
    port: System.get_env("PORT", "8080") |> String.to_integer(),
    jwt_secret:
      System.get_env("RELAY_JWT_SECRET") ||
        raise("RELAY_JWT_SECRET environment variable is required in production")
end

# Admin key and auth settings (all environments)
if admin_key = System.get_env("RELAY_ADMIN_KEY") do
  config :a2a_relay, admin_key: admin_key
end

case System.get_env("RELAY_AUTH_REQUIRED") do
  "false" -> config :a2a_relay, auth_required: false
  "0" -> config :a2a_relay, auth_required: false
  _ -> :ok
end
