defmodule Sentry.LoggerBackend do
  @moduledoc """
  This module makes use of Elixir 1.7's new Logger metadata to report
  crashed processes.  It replaces the previous `Sentry.Logger` sytem.

  To include the backend in your application, the backend can be added in your
  configuration file:

      config :logger,
        backends: [:console, Sentry.LoggerBackend]

  If you are on OTP 21+ and would like to configure the backend to include metadata from
  `Logger.metadata/0` in reported events, it can be enabled:

      config :logger, Sentry.LoggerBackend,
        include_logger_metadata: true

  It is important to be aware of whether this will include sensitive information
  in Sentry events before enabling it.

  ## Options

  The supported options are:

    * `:include_logger_metadata` - Enabling this option will read any key/value
      pairs with with binary, atom or number values from `Logger.metadata/0`
      and include that dictionary under the `:logger_metadata` key in an
      event's `:extra` metadata.  This option defaults to `false`.
    * `:ignore_plug` - Enabling this option will ignore any events that
      appear to be from a Plug process crashing.  This is to prevent
      duplicate errors being reported to Sentry alongside `Sentry.Plug`.
  """
  @behaviour :gen_event

  defstruct level: nil, include_logger_metadata: false, ignore_plug: true

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
    %{include_logger_metadata: include_logger_metadata, ignore_plug: ignore_plug} = state

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
        if ignore_plug &&
             Enum.any?(stacktrace, fn {module, function, arity, _file_line} ->
               match?({^module, ^function, ^arity}, {Plug.Cowboy.Handler, :init, 2}) ||
                 match?({^module, ^function, ^arity}, {Phoenix.Endpoint.Cowboy2Handler, :init, 2}) ||
                 match?({^module, ^function, ^arity}, {Phoenix.Endpoint.Cowboy2Handler, :init, 4})
             end) do
          :ok
        else
          opts =
            opts
            |> Keyword.put(:event_source, :logger)
            |> Keyword.put(:stacktrace, stacktrace)

          Sentry.capture_exception(reason, opts)
        end

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
    level = Keyword.get(config, :level, state.level)

    include_logger_metadata =
      Keyword.get(config, :include_logger_metadata, state.include_logger_metadata)

    ignore_plug = Keyword.get(config, :ignore_plug, state.ignore_plug)

    %{
      state
      | level: level,
        include_logger_metadata: include_logger_metadata,
        ignore_plug: ignore_plug
    }
  end

  defp build_logger_metadata(meta) do
    meta
    |> Enum.filter(fn {_key, value} ->
      case Jason.encode(value) do
        {:ok, _} -> true
        _ -> false
      end
    end)
    |> Enum.into(%{})
  end
end
