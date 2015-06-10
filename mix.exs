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
    if Mix.env == :test, do: applications = [:logger|applications]
    [
      applications: applications
    ]
  end

  defp deps do
    [
      {:hackney, "~> 1.0"},
      {:uuid, "~> 0.1.5"},
      {:poison, ">= 1.2.0"}
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
