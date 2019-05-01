defmodule Sentry.LoggerBackend do
  @moduledoc """
  This module makes use of Elixir 1.7's new Logger metadata to report
  crashed processes.  It replaces the previous `Sentry.Logger` sytem.

  To include the backend in your application, the backend can be added in your
  application file:

    def start(_type, _opts) do
      children = [
        supervisor(MyApp.Repo, []),
        supervisor(MyAppWeb.Endpoint, [])
      ]

      opts = [strategy: :one_for_one, name: MyApp.Supervisor]

      {:ok, _} = Logger.add_backend(Sentry.LoggerBackend)

      Supervisor.start_link(children, opts)
    end

  If you are on OTP 21+ and would like to configure the backend to include metadata from
  `Logger.metadata/0` in reported events, it can be enabled:

      {:ok, _} = Logger.add_backend(Sentry.LoggerBackend)
      Logger.configure_backend(Sentry.LoggerBackend, include_logger_metadata: true)


  It is important to be aware of whether this will include sensitive information
  in Sentry events before enabling it.

  ## Options

  The supported options are:

    * `:include_logger_metadata` - Enabling this option will read any key/value
      pairs with with binary, atom or number values from `Logger.metadata/0`
      and include that dictionary under the `:logger_metadata` key in an
      event's `:extra` metadata.  This option defaults to `false`.
  """
  @behaviour :gen_event

  defstruct level: nil, include_logger_metadata: false

  def init(__MODULE__) do
    config = Application.get_env(:logger, __MODULE__, [])
    {:ok, init(config, %__MODULE__{})}
  end

  def init({__MODULE__, opts}) when is_list(opts) do
    config =
      Application.get_env(:logger, __MODULE__, [])
      |> Keyword.merge(opts)

    {:ok, init(config, %__MODULE__{})}
  end

  def handle_call({:configure, options}, state) do
    config =
      Application.get_env(:logger, __MODULE__, [])
      |> Keyword.merge(options)

    Application.put_env(:logger, __MODULE__, config)
    state = init(config, state)
    {:ok, :ok, state}
  end

  def handle_event({_level, gl, {Logger, _, _, _}}, state) when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({_level, _gl, {Logger, _msg, _ts, meta}}, state) do
    %{include_logger_metadata: include_logger_metadata} = state

    opts =
      if include_logger_metadata do
        [
          extra: %{
            logger_metadata: build_logger_metadata(meta)
          }
        ]
      else
        []
      end

    case Keyword.get(meta, :crash_reason) do
      {reason, stacktrace} ->
        opts =
          opts
          |> Keyword.put(:event_source, :logger)
          |> Keyword.put(:stacktrace, stacktrace)

        Sentry.capture_exception(reason, opts)

      reason when is_atom(reason) and not is_nil(reason) ->
        Sentry.capture_exception(reason, [{:event_source, :logger} | opts])

      _ ->
        :ok
    end

    {:ok, state}
  end

  def handle_event(:flush, state) do
    {:ok, state}
  end

  def handle_event(_, state) do
    {:ok, state}
  end

  def handle_info(_, state) do
    {:ok, state}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  defp init(config, %__MODULE__{} = state) do
    level = Keyword.get(config, :level)
    include_logger_metadata = Keyword.get(config, :include_logger_metadata)
    %{state | level: level, include_logger_metadata: include_logger_metadata}
  end

  defp build_logger_metadata(meta) do
    meta
    |> Enum.filter(fn {_key, value} ->
      is_binary(value) || is_atom(value) || is_number(value)
    end)
    |> Enum.into(%{})
  end
end
