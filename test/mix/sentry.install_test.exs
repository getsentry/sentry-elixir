defmodule Mix.Tasks.Sentry.InstallTest do
  use Sentry.Case, async: false

  import Igniter.Test

  setup do
    [
      igniter:
        test_project(
          files: %{
            "lib/test_web/endpoint.ex" => """
            defmodule TestWeb.Endpoint do
              use Phoenix.Endpoint, otp_app: :test

              plug(Plug.Parsers,
                parsers: [:urlencoded, :multipart, :json],
                pass: ["*/*"],
                json_decoder: Phoenix.json_library()
              )

              plug(TestWeb.Router)
            end
            """,
            "lib/test_web/router.ex" => """
            defmodule TestWeb.Router do
              use Phoenix.Router

              scope "/", TestWeb do
                get "/", PageController, :index
              end
            end
            """
          }
        )
        |> Igniter.Project.Application.create_app(Test.Application)
        |> apply_igniter!()
    ]
  end

  test "installation adds jason and finch dependencies", %{igniter: igniter} do
    igniter
    |> Igniter.compose_task("sentry.install", ["--dsn", "test_dsn"])
    |> assert_creates("config/prod.exs", """
    import Config

    config :sentry,
      dsn: "test_dsn",
      environment_name: config_env(),
      enable_source_code_context: true,
      root_source_code_paths: [File.cwd!()]
    """)
    |> assert_has_patch("lib/test_web/endpoint.ex", """
    + |  plug(Sentry.PlugContext)
    """)
    |> assert_has_patch("lib/test/application.ex", """
    + |    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
    + |      config: %{metadata: [:file, :line]}
    + |    })
    """)
  end

  test "installation does not add Sentry.PlugCapture without plug_cowboy", %{igniter: igniter} do
    endpoint =
      igniter
      |> Igniter.compose_task("sentry.install", ["--dsn", "test_dsn"])
      |> apply_igniter!()
      |> then(& &1.assigns[:test_files]["lib/test_web/endpoint.ex"])

    refute endpoint =~ "Sentry.PlugCapture"
  end

  test "installation adds Sentry.PlugCapture when the project uses plug_cowboy", %{
    igniter: igniter
  } do
    igniter
    |> Igniter.Project.Deps.add_dep({:plug_cowboy, "~> 2.7"})
    |> apply_igniter!()
    |> Igniter.compose_task("sentry.install", ["--dsn", "test_dsn"])
    |> assert_has_patch("lib/test_web/endpoint.ex", """
    + |  use Sentry.PlugCapture
    """)
  end

  test "installation is idempotent", %{igniter: igniter} do
    igniter
    |> Igniter.compose_task("sentry.install", ["--dsn", "test_dsn"])
    |> apply_igniter!()
    |> Igniter.compose_task("sentry.install", ["--dsn", "test_dsn"])
    |> assert_unchanged()
  end

  test "installation will reset your dsn for you, however", %{igniter: igniter} do
    igniter
    |> Igniter.compose_task("sentry.install", ["--dsn", "test_dsn"])
    |> apply_igniter!()
    |> Igniter.compose_task("sentry.install", ["--dsn", "test_dsn2"])
    |> assert_has_patch("config/prod.exs", """
    - |  dsn: "test_dsn",
    + |  dsn: "test_dsn2",
    """)
  end
end
