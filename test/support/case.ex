defmodule Sentry.Case do
  # We use this module mostly to add some additional checks before and after tests, especially
  # related to configuration. Configuration is a bit finicky due to the extensive use of
  # global state (:persistent_term), so better safe than sorry here.

  use ExUnit.CaseTemplate

  import Sentry.TestHelpers

  setup context do
    config_before = all_config()

    on_exit(fn ->
      assert config_before == all_config()
    end)

    case context[:span_storage] do
      nil -> :ok
      true -> setup_span_storage([])
      opts when is_list(opts) -> setup_span_storage(opts)
    end
  end

  defp setup_span_storage(opts) do
    uid = System.unique_integer([:positive])
    server_name = :"test_span_storage_#{uid}"
    table_name = :"test_span_storage_table_#{uid}"

    opts = [name: server_name, table_name: table_name] ++ opts
    start_supervised!({Sentry.OpenTelemetry.SpanStorage, opts})

    {:ok, server_name: server_name, table_name: table_name}
  end
end
