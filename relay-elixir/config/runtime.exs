import Config

if config_env() == :prod do
  config :a2a_relay,
    port: System.get_env("PORT", "8080") |> String.to_integer(),
    jwt_secret:
      System.get_env("RELAY_JWT_SECRET") ||
        raise("RELAY_JWT_SECRET environment variable is required in production")
end
