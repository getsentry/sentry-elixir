defmodule Sentry.Application do
  @moduledoc false

  use Application

  alias Sentry.Config

  @impl true
  def start(_type, _opts) do
    children = [
      {Registry, keys: :unique, name: Sentry.Transport.SenderRegistry},
      Config.client().child_spec(),
      Sentry.Transport.SenderPool
    ]

    if Config.client() == Sentry.HackneyClient do
      unless Code.ensure_loaded?(:hackney) do
        raise """
        cannot start the :sentry application because the HTTP client is set to \
        Sentry.HackneyClient (which is the default), but the Hackney library is not loaded. \
        Add :hackney to your dependencies to fix this.
        """
      end

      case Application.ensure_all_started(:hackney) do
        {:ok, _apps} -> :ok
        {:error, reason} -> raise "failed to start the :hackney application: #{inspect(reason)}"
      end
    end

    Config.warn_for_deprecated_env_vars!()
    validate_json_config!()
    Config.validate_log_level!()
    Config.validate_included_environments!()
    Config.validate_environment_name!()
    Config.assert_dsn_has_no_query_params!()

    opts = [strategy: :one_for_one, name: Sentry.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp validate_json_config!() do
    case Config.json_library() do
      nil ->
        raise ArgumentError.exception("nil is not a valid :json_library configuration")

      library ->
        try do
          with {:ok, %{}} <- library.decode("{}"),
               {:ok, "{}"} <- library.encode(%{}) do
            :ok
          else
            _ ->
              raise ArgumentError.exception(
                      "configured :json_library #{inspect(library)} does not implement decode/1 and encode/1"
                    )
          end
        rescue
          UndefinedFunctionError ->
            reraise ArgumentError.exception("""
                    configured :json_library #{inspect(library)} is not available or does not implement decode/1 and encode/1.
                    Do you need to add #{inspect(library)} to your mix.exs?
                    """),
                    __STACKTRACE__
        end
    end
  end
end
