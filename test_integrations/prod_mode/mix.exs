defmodule ProdMode.MixProject do
  use Mix.Project

  def project do
    [
      app: :prod_mode,
      version: "0.1.0",
      elixir: "~> 1.13",
      lockfile: lockfile(current_elixir_version()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ProdMode.Application, []}
    ]
  end

  defp deps do
    [
      {:sentry, path: "../.."},
      {:finch, dep_version(:finch, current_elixir_version())},
      {:jason, "~> 1.1"},
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
