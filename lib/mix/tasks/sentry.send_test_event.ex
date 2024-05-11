defmodule Mix.Tasks.Sentry.SendTestEvent do
  use Mix.Task
  alias Sentry.Config

  @shortdoc "Send a test event to Sentry to check your Sentry configuration"

  @moduledoc """
  Sends a test event to Sentry to check if your Sentry configuration is correct.

  This task reports a `RuntimeError` exception like this one:

      %RuntimeError{message: "Testing sending Sentry event"}

  ## Options

    * `--no-compile` - does not compile, even if files require compilation.
    * `--type` - `exception` or `message`. Defaults to `exception`. *Available since v10.1.0.*.
    * `--no-stacktrace` - does not include a stacktrace in the reported event. *Available since
      v10.1.0.*.

  """

  @switches [
    compile: :boolean,
    stacktrace: :boolean,
    type: :string
  ]

  @impl true
  def run(args) when is_list(args) do
    {opts, args} = OptionParser.parse!(args, strict: @switches)

    if Keyword.get(opts, :compile, true) do
      Mix.Task.run("compile", args)
    end

    Mix.Task.run("loadconfig")
    Mix.Task.run("app.config")

    case Application.ensure_all_started(:sentry) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        Mix.raise("Failed to start the :sentry application:\n\n#{inspect(reason)}")
    end

    print_environment_info()

    if Config.dsn() do
      send_event(opts)
    else
      Mix.shell().info([
        :yellow,
        "Event not sent because the :dsn option is not set (or set to nil)"
      ])
    end
  end

  defp print_environment_info do
    Mix.shell().info("Client configuration:")

    if dsn = Config.dsn() do
      Mix.shell().info("server: #{dsn.endpoint_uri}")
      Mix.shell().info("public_key: #{dsn.public_key}")
      Mix.shell().info("secret_key: #{dsn.secret_key}")
    end

    Mix.shell().info("current environment_name: #{inspect(to_string(Config.environment_name()))}")
    Mix.shell().info("hackney_opts: #{inspect(Config.hackney_opts())}\n")
  end

  defp send_event(opts) do
    stacktrace_opts =
      if Keyword.get(opts, :stacktrace, true) do
        {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
        [stacktrace: stacktrace]
      else
        []
      end

    Mix.shell().info("Sending test event...")

    result =
      case Keyword.get(opts, :type, "exception") do
        "exception" ->
          exception = %RuntimeError{message: "Testing sending Sentry event"}
          Sentry.capture_exception(exception, [result: :sync] ++ stacktrace_opts)

        "message" ->
          Sentry.capture_message(
            "Testing sending Sentry event",
            [result: :sync] ++ stacktrace_opts
          )
      end

    case result do
      {:ok, id} ->
        Mix.shell().info([:green, :bright, "Test event sent", :reset, "\nEvent ID: #{id}"])

      {:error, reason} ->
        Mix.raise("Error sending event:\n\n#{inspect(reason)}")

      :excluded ->
        Mix.shell().info("No test event was sent because the event was excluded by a filter")

      :unsampled ->
        Mix.shell().info("""
        No test event was sent because the event was excluded according to the :sample_rate \
        configuration option.
        """)
    end
  end
end
