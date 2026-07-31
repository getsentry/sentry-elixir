defmodule ReportingJSONLibrary do
  @moduledoc false

  # A `:json_library` drop-in that reports which process performed an encode.
  #
  # Used to assert that expensive work (like computing byte-based client report
  # outcomes) happens off the caller's process. Delegates to the real library so
  # behaviour is otherwise unchanged.

  @key {__MODULE__, :report_to}

  @doc """
  Sends `{:encoded, encoding_pid}` to `pid` on every non-trivial encode.

  Empty maps are ignored so that `Sentry.Config`'s own validation encode (which
  runs on whichever process calls `put_test_config/1`) isn't reported.
  """
  @spec report_to(pid()) :: :ok
  def report_to(pid) when is_pid(pid) do
    :persistent_term.put(@key, pid)
  end

  def encode(data) do
    if data != %{} do
      case :persistent_term.get(@key, nil) do
        nil -> :ok
        pid -> send(pid, {:encoded, self()})
      end
    end

    Sentry.JSON.encode(data, default_library())
  end

  def decode(binary) do
    Sentry.JSON.decode(binary, default_library())
  end

  defp default_library do
    if Code.ensure_loaded?(JSON), do: JSON, else: Jason
  end
end
