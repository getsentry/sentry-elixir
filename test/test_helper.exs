Code.load_file("test/support/test_plug.ex")
Code.require_file("test/support/test_environment_helper.exs")
Code.require_file("test/support/test_before_send_event.exs")
Code.require_file("test/support/test_filter.exs")
Code.require_file("test/support/test_gen_server.exs")
Code.require_file("test/support/test_client.exs")

ExUnit.start()
Application.ensure_all_started(:bypass)
