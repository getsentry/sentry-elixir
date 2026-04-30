defmodule ProdMode.MixProject do
  use Mix.Project

  def project do
    [
      app: :prod_mode,
      version: "0.1.0",
      elixir: "~> 1.13",
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
      {:finch, "~> 0.17"},
      {:jason, "~> 1.1"}
    ]
  end
end
