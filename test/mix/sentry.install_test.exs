defmodule Mix.Tasks.Sentry.InstallTest do
  use Sentry.Case, async: false

  import Igniter.Test

  test "installation adds jason and hackney dependencies" do
    phx_test_project()
    |> Igniter.compose_task("sentry.install", ["--dsn", "test_dsn"])
    |> assert_has_patch("config/prod.exs", """
    + |config :test,
    + |  dsn: "test_dsn",
    + |  environment_name: Mix.env(),
    + |  enable_source_code_context: true,
    + |  root_source_code_paths: [File.cwd!()]
    """)
    |> assert_has_patch("lib/test_web/endpoint.ex", """
    + |  use Sentry.PlugCapture
    """)
    |> assert_has_patch("lib/test_web/endpoint.ex", """
    + |  use Sentry.PlugContext
    """)
    |> assert_has_patch("lib/test/application.ex", """
    + |    :logger.add_handler(:my_sentry_handler, Sentry.LoggerHandler, %{
    + |      config: %{metadata: [:file, :line]}
    + |    })
    """)
  end
end
