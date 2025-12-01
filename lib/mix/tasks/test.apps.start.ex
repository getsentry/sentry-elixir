defmodule Mix.Tasks.Test.Apps.Start do
  use Mix.Task

  @shortdoc "Start an integration test app for manual testing"

  @moduledoc """
  Starts an integration test application for manual testing with a custom DSN.

  ## Usage

      $ mix test.apps.start --app phoenix_app --dsn YOUR_DSN

  ## Options

    * `--app` - The integration app to start. Available apps:
      * `phoenix_app` (default) - Phoenix LiveView application with Oban and OpenTelemetry

    * `--dsn` - The Sentry DSN to use (required). Can be a full DSN URL or
      omitted to use the DSN from environment variables.

    * `--environment` - The environment name to report to Sentry (default: "manual-test")

  ## Examples

      # Start phoenix_app with a custom DSN
      $ mix test.apps.start --dsn https://public@sentry.io/123

      # Use DSN from SENTRY_DSN environment variable
      $ export SENTRY_DSN=https://public@sentry.io/123
      $ mix test.apps.start

  """

  @switches [
    app: :string,
    dsn: :string,
    environment: :string
  ]

  @available_apps ["phoenix_app"]

  @impl true
  def run(args) when is_list(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)

    app = Keyword.get(opts, :app, "phoenix_app")
    dsn = Keyword.get(opts, :dsn) || System.get_env("SENTRY_DSN")
    environment = Keyword.get(opts, :environment, "manual-test")

    unless app in @available_apps do
      Mix.raise("""
      Invalid app: #{app}

      Available apps:
      #{Enum.map_join(@available_apps, "\n", &"  - #{&1}")}
      """)
    end

    unless dsn do
      Mix.raise("""
      No DSN provided. Please provide a DSN via:
        --dsn flag: mix test.apps.start --dsn YOUR_DSN
        Or set SENTRY_DSN environment variable
      """)
    end

    app_path = Path.join("test_integrations", app)

    unless File.dir?(app_path) do
      Mix.raise("Integration app not found: #{app_path}")
    end

    Mix.shell().info([
      :cyan,
      :bright,
      "\n==> Starting integration app: #{app}",
      :reset
    ])

    Mix.shell().info("DSN: #{mask_dsn(dsn)}")
    Mix.shell().info("Environment: #{environment}\n")

    # Set up dependencies
    Mix.shell().info("Installing dependencies...")

    case System.cmd("mix", ["deps.get"], cd: app_path, into: IO.stream(:stdio, :line)) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("Failed to install dependencies (exit status: #{status})")
    end

    # Check if overmind is available
    case System.cmd("which", ["overmind"], stderr_to_stdout: true) do
      {_, 0} ->
        # Set environment variables
        env = [
          {"SENTRY_DSN", dsn},
          {"SENTRY_ENVIRONMENT", environment}
        ]

        # Start the application
        Mix.shell().info([
          :green,
          :bright,
          "\n==> Starting #{app} with Overmind...",
          :reset,
          "\n"
        ])

        System.cmd("overmind", ["start"],
          cd: app_path,
          into: IO.stream(:stdio, :line),
          env: env
        )

      _ ->
        Mix.raise("""
        Overmind is not installed. Please install it:

        macOS: brew install overmind tmux
        Linux: go install github.com/DarthSim/overmind/v2@latest

        Then add to PATH: export PATH=$PATH:$(go env GOPATH)/bin
        """)
    end
  end

  defp mask_dsn(dsn) do
    case URI.parse(dsn) do
      %URI{userinfo: userinfo} when is_binary(userinfo) ->
        String.replace(dsn, userinfo, "***")

      _ ->
        dsn
    end
  end
end
