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

  """

  @impl true
  def run(args) when is_list(args) do
    unless "--no-compile" in args do
      Mix.Task.run("compile", args)
    end

    case Application.ensure_all_started(:sentry) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        Mix.raise("Failed to start the :sentry application:\n\n#{inspect(reason)}")
    end

    included_environments = Config.included_environments()

    print_environment_info(Sentry.Transport.get_dsn(), included_environments)

    env_name = to_string(Config.environment_name())

    if included_environments == :all or env_name in included_environments do
      send_event()
    else
      Mix.shell().info([
        :yellow,
        "#{inspect(env_name)} is not in #{inspect(included_environments)} so no test event will be sent"
      ])
    end
  end

  defp print_environment_info({endpoint, public_key, secret_key}, included_environments) do
    Mix.shell().info("Client configuration:")
    Mix.shell().info("server: #{endpoint}")
    Mix.shell().info("public_key: #{public_key}")
    Mix.shell().info("secret_key: #{secret_key}")
    Mix.shell().info("included_environments: #{inspect(included_environments)}")
    Mix.shell().info("current environment_name: #{inspect(to_string(Config.environment_name()))}")
    Mix.shell().info("hackney_opts: #{inspect(Config.hackney_opts())}\n")
  end

  defp send_event do
    Mix.shell().info("Sending test event...")

    exception = %RuntimeError{message: "Testing sending Sentry event"}
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

    case Sentry.capture_exception(exception, result: :sync, stacktrace: stacktrace) do
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
