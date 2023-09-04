defmodule Mix.Tasks.Sentry.SendTestEvent do
  use Mix.Task
  alias Sentry.Config

  @shortdoc "Attempts to send a test event to check Sentry configuration"
  @moduledoc """
  Send test even to check if Sentry configuration is correct.
  """

  def run(args) do
    unless "--no-compile" in args do
      Mix.Task.run("compile", args)
    end

    Application.ensure_all_started(:sentry)

    Sentry.Transport.get_dsn()
    |> print_environment_info()

    maybe_send_event()
  end

  defp print_environment_info({endpoint, public_key, secret_key}) do
    Mix.shell().info("Client configuration:")
    Mix.shell().info("server: #{endpoint}")
    Mix.shell().info("public_key: #{public_key}")
    Mix.shell().info("secret_key: #{secret_key}")
    Mix.shell().info("included_environments: #{inspect(included_environments())}")
    Mix.shell().info("current environment_name: #{inspect(to_string(Config.environment_name()))}")
    Mix.shell().info("hackney_opts: #{inspect(Config.hackney_opts())}\n")
  end

  defp included_environments do
    case Application.fetch_env(:sentry, :included_environments) do
      {:ok, envs} when is_list(envs) or envs == :all ->
        envs

      _ ->
        Mix.raise(
          "Sentry included_environments is not configured in :sentry, :included_environments"
        )
    end
  end

  defp maybe_send_event do
    env_name = to_string(Config.environment_name())
    included_envs = included_environments()

    if included_envs == :all or env_name in included_envs do
      Mix.shell().info("Sending test event...")

      {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

      result =
        "Testing sending Sentry event"
        |> RuntimeError.exception()
        |> Sentry.capture_exception(result: :sync, stacktrace: stacktrace)

      case result do
        {:ok, id} ->
          Mix.shell().info("Test event sent!  Event ID: #{id}")

        {:error, reason} ->
          Mix.shell().info("Error sending event: #{inspect(reason)}")

        :excluded ->
          Mix.shell().info("No test event was sent because the event was excluded by a filter")

        :unsampled ->
          Mix.shell().info(
            "No test event was sent because the event was excluded according to the sample_rate"
          )
      end
    else
      Mix.shell().info(
        "#{inspect(env_name)} is not in #{inspect(included_envs)} so no test event will be sent"
      )
    end
  end
end
