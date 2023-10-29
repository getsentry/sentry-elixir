defmodule Sentry.Application do
  @moduledoc false

  use Application

  alias Sentry.{Config, Sources}

  @impl true
  def start(_type, _opts) do
    http_client = Config.client()

    maybe_http_client_spec =
      if Code.ensure_loaded?(http_client) and function_exported?(http_client, :child_spec, 0) do
        [http_client.child_spec()]
      else
        []
      end

    children =
      [{Registry, keys: :unique, name: Sentry.Transport.SenderRegistry}] ++
        maybe_http_client_spec ++
        [Sentry.Transport.SenderPool]

    Config.warn_for_deprecated_env_vars!()
    validate_json_config!()
    Config.validate_log_level!()
    Config.validate_included_environments!()
    Config.validate_environment_name!()
    Config.assert_dsn_has_no_query_params!()

    cache_loaded_applications()
    Sources.load_source_code_map_if_present()

    Supervisor.start_link(children, strategy: :one_for_one, name: Sentry.Supervisor)
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

  defp cache_loaded_applications do
    apps_with_vsns =
      if Config.report_deps?() do
        Map.new(Application.loaded_applications(), fn {app, _description, vsn} ->
          {Atom.to_string(app), to_string(vsn)}
        end)
      else
        %{}
      end

    :persistent_term.put({:sentry, :loaded_applications}, apps_with_vsns)
  end
end
