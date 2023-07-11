Code.compile_file("test/support/example_plug_application.ex")
Code.require_file("test/support/test_environment_helper.exs")
Code.require_file("test/support/test_before_send_event.exs")
Code.require_file("test/support/test_filter.exs")
Code.require_file("test/support/test_gen_server.exs")
Code.require_file("test/support/test_error_view.exs")

ExUnit.start(assert_receive_timeout: 500)

Application.ensure_all_started(:bypass)
Application.ensure_all_started(:telemetry)
