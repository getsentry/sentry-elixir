defmodule LegacyTelemetryPoller.MixProject do
  use Mix.Project

  def project do
    [
      app: :legacy_telemetry_poller,
      version: "0.1.0",
      elixir: "~> 1.13",
      lockfile: lockfile(current_elixir_version()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:sentry, path: "../.."},
      {:hackney, "~> 1.20"},
      {:jason, "~> 1.1"},
      {:telemetry, "~> 0.4.3"},
      {:telemetry_poller, "~> 0.5.0"},
      {:bypass, "~> 2.0", only: :test}
    ]
  end

  defp current_elixir_version, do: Version.parse!(System.version())

  defp lockfile(%Version{major: 1, minor: minor}) when minor < 18,
    do: "mix-1.15-1.17.lock"

  defp lockfile(%Version{}), do: "mix.lock"
end
