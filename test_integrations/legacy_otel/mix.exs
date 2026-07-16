defmodule LegacyOtel.MixProject do
  use Mix.Project

  def project do
    [
      app: :legacy_otel,
      version: "0.1.0",
      elixir: "~> 1.13",
      lockfile: lockfile(current_elixir_version()),
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
      {:finch, dep_version(:finch, current_elixir_version())},
      {:jason, "~> 1.1", optional: true},
      {:opentelemetry, "~> 1.3.0"},
      {:opentelemetry_api, "~> 1.2"},
      {:opentelemetry_exporter, "~> 1.4.0"},
      {:opentelemetry_semantic_conventions, "~> 0.2"},
      {:hpax, dep_version(:hpax, current_elixir_version()), override: true}
    ]
  end

  defp current_elixir_version, do: Version.parse!(System.version())

  defp dep_version(:finch, %Version{major: 1, minor: minor}) when minor < 15,
    do: "~> 0.17 and < 0.22.0"

  defp dep_version(:finch, %Version{}), do: "~> 0.17"

  defp dep_version(:hpax, %Version{major: 1, minor: minor}) when minor < 15,
    do: "~> 1.0.0 and < 1.0.4"

  defp dep_version(:hpax, %Version{}), do: "~> 1.0"

  defp lockfile(%Version{major: 1, minor: minor}) when minor < 15,
    do: "mix-1.13-1.14.lock"

  defp lockfile(%Version{major: 1, minor: minor}) when minor < 18,
    do: "mix-1.15-1.17.lock"

  defp lockfile(%Version{}), do: "mix.lock"
end
