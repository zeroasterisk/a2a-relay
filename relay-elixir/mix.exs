defmodule A2aRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :a2a_relay,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {A2aRelay.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.14"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
