defmodule LegacyOtel.MixProject do
  use Mix.Project

  def project do
    [
      app: :legacy_otel,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:sentry, path: "../.."},
      {:finch, "~> 0.17"},
      {:jason, "~> 1.1", optional: true},
      {:opentelemetry, "~> 1.3.0"},
      {:opentelemetry_api, "~> 1.2"},
      {:opentelemetry_exporter, "~> 1.4.0"},
      {:opentelemetry_semantic_conventions, "~> 0.2"}
    ]
  end
end
