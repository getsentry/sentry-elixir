defmodule TracingTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :tracing_test,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:httpoison, "~> 2.0"}
    ]
  end

  defp aliases do
    [
      test: &run_playwright_tests/1,
      setup: &setup_environment/1,
      "dev.start": &start_dev_servers/1
    ]
  end

  defp setup_environment(_args) do
    Mix.shell().info("Installing npm dependencies...")
    System.cmd("npm", ["install"], into: IO.stream(:stdio, :line))

    # Install Playwright browsers
    Mix.shell().info("Installing Playwright browsers...")
    System.cmd("npx", ["playwright", "install"], into: IO.stream(:stdio, :line))

    # Setup phoenix_app dependencies
    phoenix_app_path = Path.join([__DIR__, "..", "phoenix_app"])
    Mix.shell().info("Installing Phoenix app dependencies...")
    System.cmd("mix", ["deps.get"], cd: phoenix_app_path, into: IO.stream(:stdio, :line))

    Mix.shell().info("Setup complete!")
  end

  defp start_dev_servers(_args) do
    # Check if overmind is available
    case System.cmd("which", ["overmind"], stderr_to_stdout: true) do
      {_, 0} ->
        Mix.shell().info("Starting servers with Overmind...")
        System.cmd("overmind", ["start"], into: IO.stream(:stdio, :line))

      _ ->
        Mix.shell().error("""
        Overmind is not installed. Please install it:

        macOS: brew install overmind tmux
        Linux: go install github.com/DarthSim/overmind/v2@latest

        Then add to PATH: export PATH=$PATH:$(go env GOPATH)/bin
        """)
        System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end

  defp run_playwright_tests(args) do
    # Install npm dependencies if needed
    if !File.dir?("node_modules") do
      Mix.shell().info("Installing npm dependencies...")
      System.cmd("npm", ["install"], into: IO.stream(:stdio, :line))
    end

    # Build test command
    test_cmd = ["test" | args]

    # Run Playwright tests
    Mix.shell().info("Running Playwright tests...")
    {_, exit_code} = System.cmd("npm", test_cmd, into: IO.stream(:stdio, :line))

    if exit_code != 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end
end
