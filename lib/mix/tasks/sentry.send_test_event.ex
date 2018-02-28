defmodule Mix.Tasks.Sentry.SendTestEvent do
  use Mix.Task
  alias Sentry.Config

  @shortdoc "Attempts to send a test event to check Sentry configuration"
  @moduledoc """
  Send test even to check if Sentry configuration is correct.
  """

  def run(args) do
    unless "--no-compile" in args do
      Mix.Project.compile(args)
    end

    Application.ensure_all_started(:sentry)

    Sentry.Client.get_dsn()
    |> print_environment_info()

    maybe_send_event()
  end

  defp print_environment_info({endpoint, public_key, secret_key}) do
    Mix.shell().info("Client configuration:")
    Mix.shell().info("server: #{endpoint}")
    Mix.shell().info("public_key: #{public_key}")
    Mix.shell().info("secret_key: #{secret_key}")
    Mix.shell().info("included_environments: #{inspect(included_environments())}")
    Mix.shell().info("current environment_name: #{inspect(Config.environment_name())}")
    Mix.shell().info("hackney_opts: #{inspect(Config.hackney_opts())}\n")
  end

  defp included_environments do
    case Application.fetch_env(:sentry, :included_environments) do
      {:ok, envs} when is_list(envs) ->
        envs

      _ ->
        Mix.raise(
          "Sentry included_environments is not configured in :sentry, :included_environments"
        )
    end
  end

  defp maybe_send_event do
    env_name = Config.environment_name()
    included_envs = included_environments()

    if env_name in included_envs do
      Mix.shell().info("Sending test event...")

      result =
        "Testing sending Sentry event"
        |> RuntimeError.exception()
        |> Sentry.capture_exception(result: :sync)

      case result do
        {:ok, id} ->
          Mix.shell().info("Test event sent!  Event ID: #{id}")

        :error ->
          Mix.shell().info("Error sending event!")

        :excluded ->
          Mix.shell().info("No test event was sent because the event was excluded by a filter")
      end
    else
      Mix.shell().info(
        "#{inspect(env_name)} is not in #{inspect(included_envs)} so no test event will be sent"
      )
    end
  end
end
