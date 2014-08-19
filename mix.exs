defmodule Raven.Mixfile do
  use Mix.Project

  def project do
    [
      app: :raven,
      version: "0.0.1",
      elixir: "~> 0.15.1",
      deps: deps
    ]
  end

  def application do
    applications = [:httpoison, :hackney, :uuid, :jiffy]
    if Mix.env == :test, do: applications = [:logger|applications]
    [
      applications: applications
    ]
  end

  defp deps do
    [
      {:httpoison, "~> 0.4.0"},
      {:uuid, "~> 0.1.5"},
      {:jiffy, github: "vishnevskiy/jiffy"}
    ]
  end
end
