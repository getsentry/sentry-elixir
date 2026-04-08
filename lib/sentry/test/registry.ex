defmodule Sentry.Test.Registry do
  @moduledoc false

  use GenServer

  # Bypass and Plug.Conn may not be available at compile time (optional deps).
  @compile {:no_warn_undefined, [Bypass, Bypass.Instance, Bypass.Supervisor, Plug.Conn]}

  @table :sentry_test_collectors

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link([] = _opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc false
  @spec default_dsn :: String.t() | nil
  def default_dsn do
    :persistent_term.get(:sentry_test_default_bypass_dsn, nil)
  end

  @impl true
  def init(nil) do
    _table = :ets.new(@table, [:named_table, :public, :set])
    maybe_start_default_bypass()
    {:ok, :no_state}
  end

  # Starts a global Bypass instance that acts as a silent HTTP sink for all tests.
  # This ensures every test has a valid DSN even without calling setup_sentry/1,
  # preserving backward compatibility where capture_* returns {:ok, ""}.
  defp maybe_start_default_bypass do
    dsn_already_set? = not is_nil(Sentry.Config.dsn())
    bypass_available? = Code.ensure_loaded?(Bypass)

    if not dsn_already_set? and bypass_available? do
      {:ok, _apps} = Application.ensure_all_started(:bypass)

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Bypass.Supervisor,
          Bypass.Instance.child_spec([])
        )

      port = Bypass.Instance.call(pid, :port)
      bypass = struct!(Bypass, pid: pid, port: port)

      # Stub with empty ID to match master's {:ok, ""} return value
      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": ""}>)
      end)

      dsn_string = "http://public:secret@localhost:#{port}/1"
      :persistent_term.put(:sentry_test_default_bypass_dsn, dsn_string)
      Sentry.put_config(:dsn, dsn_string)
    end
  end
end
