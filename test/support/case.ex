defmodule Sentry.Case do
  # We use this module mostly to add some additional checks before and after tests, especially
  # related to configuration. Configuration is a bit finicky due to the extensive use of
  # global state (:persistent_term), so better safe than sorry here.

  use ExUnit.CaseTemplate

  import Sentry.TestHelpers

  setup do
    config_before = all_config()

    on_exit(fn ->
      assert config_before == all_config()
    end)
  end
end
