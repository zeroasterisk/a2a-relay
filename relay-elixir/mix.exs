defmodule A2aRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :a2a_relay,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      deps: deps(),
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def releases do
    [
      a2a_relay: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
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
