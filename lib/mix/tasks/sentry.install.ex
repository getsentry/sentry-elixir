defmodule Mix.Tasks.Sentry.Install.Docs do
  @moduledoc false

  def short_doc do
    "Installs sentry. Requires igniter to be installed."
  end

  def example do
    "mix sentry.install --dsn <your_dsn>"
  end

  def long_doc do
    """
    #{short_doc()}

    This installer is built with, and requires, igniter to be used. Igniter is a tool
    for biulding package installers. For information on how to add igniter to your
    project, see the documentation https://hexdocs.pm/igniter/readme.html#installation.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

      * `--dsn` - Your Sentry DSN.

    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Sentry.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :sentry,
        adds_deps: [{:jason, "~> 1.2"}, {:hackney, "~> 1.8"}],
        example: __MODULE__.Docs.example(),
        schema: [dsn: :string],
        defaults: [dsn: "<your_dsn>"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)

      igniter
      |> Igniter.Project.Config.configure(
        "prod.exs",
        app_name,
        [:dsn],
        igniter.args.options[:dsn]
      )
      |> Igniter.Project.Config.configure(
        "prod.exs",
        app_name,
        [:environment_name],
        {:code, quote(do: Mix.env())}
      )
      |> Igniter.Project.Config.configure(
        "prod.exs",
        app_name,
        [:enable_source_code_context],
        true
      )
      |> Igniter.Project.Config.configure(
        "prod.exs",
        app_name,
        [:root_source_code_paths],
        {:code, quote(do: [File.cwd!()])}
      )
      |> configure_phoenix()
      |> add_logger_handler()
      |> Igniter.add_notice("""
      Sentry:

        Add a call to

          mix sentry.package_source_code

        in your release script to make sure the stacktraces you receive
        are correctly categorized.
      """)
    end

    defp add_logger_handler(igniter) do
      app_module = Igniter.Project.Application.app_module(igniter)

      Igniter.Project.Module.find_and_update_module(igniter, app_module, fn zipper ->
        with {:ok, zipper} <- Igniter.Code.Function.move_to_def(zipper, :start, 2),
             :error <-
               Igniter.Code.Function.move_to_function_call_in_current_scope(
                 zipper,
                 {:logger, :add_handler},
                 [2, 3, 4],
                 &Igniter.Code.Function.argument_equals?(&1, 1, Sentry.LoggerHandler)
               ) do
          code =
            """
            :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
              config: %{metadata: [:file, :line]}
            })
            """

          {:ok, Igniter.Code.Common.add_code(zipper, code, placement: :before)}
        else
          _ -> {:ok, zipper}
        end
      end)
      |> case do
        {:ok, igniter} -> igniter
        _ -> igniter
      end
    end

    defp configure_phoenix(igniter) do
      {igniter, routers} =
        Igniter.Libs.Phoenix.list_routers(igniter)

      {igniter, endpoints} =
        Enum.reduce(routers, {igniter, []}, fn router, {igniter, endpoints} ->
          {igniter, new_endpoints} = Igniter.Libs.Phoenix.endpoints_for_router(igniter, router)
          {igniter, endpoints ++ new_endpoints}
        end)

      Enum.reduce(endpoints, igniter, fn endpoint, igniter ->
        igniter
        |> setup_endpoint(endpoint)
      end)
    end

    defp setup_endpoint(igniter, endpoint) do
      Igniter.Project.Module.find_and_update_module!(igniter, endpoint, fn zipper ->
        zipper
        |> Igniter.Code.Common.within(&add_plug_capture/1)
        |> Igniter.Code.Common.within(&add_plug_context/1)
        |> then(&{:ok, &1})
      end)
    end

    defp add_plug_capture(zipper) do
      with :error <- Igniter.Code.Module.move_to_use(zipper, Sentry.PlugCapture),
           {:ok, zipper} <- Igniter.Code.Module.move_to_use(zipper, Phoenix.Endpoint) do
        Igniter.Code.Common.add_code(zipper, "use Sentry.PlugCapture", placement: :before)
      else
        _ ->
          zipper
      end
    end

    defp add_plug_context(zipper) do
      with :error <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :plug,
               [1, 2],
               &Igniter.Code.Function.argument_equals?(&1, 0, Sentry.PlugContext)
             ),
           {:ok, zipper} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :plug,
               [1, 2],
               &Igniter.Code.Function.argument_equals?(&1, 0, Plug.Parsers)
             ) do
        Igniter.Code.Common.add_code(zipper, "plug Sentry.PlugContext", placement: :after)
      else
        _ ->
          zipper
      end
    end
  end
else
  defmodule Mix.Tasks.Sentry.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'sentry.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
