defmodule Raven.Mixfile do
  use Mix.Project

  def project do
    [
      app: :raven,
      version: "0.0.5",
      elixir: "~> 1.0",
      description: "Raven is an Elixir client for Sentry",
      package: package,
      deps: deps
    ]
  end

  def application do
    applications = [:hackney, :uuid, :poison]
    applications = if Mix.env == :test, do: [:logger|applications], else: applications
    [
      applications: applications
    ]
  end

  defp deps do
    [
      {:hackney, "~> 1.3"},
      {:uuid, "~> 1.0"},
      {:poison, "~> 1.5"}
    ]
  end

  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md"],
      contributors: ["Stanislav Vishnevskiy"],
      licenses: ["MIT"],
      links: %{
        "github" => "https://github.com/vishnevskiy/raven-elixir"
      }
    ]
  end
end
