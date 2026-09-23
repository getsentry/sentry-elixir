defmodule Sentry.Callback do
  @moduledoc false

  alias Sentry.ClientReport
  alias Sentry.LoggerUtils

  @type spec() :: (... -> term()) | {module(), atom()}

  @spec run(atom(), (-> result), result, keyword()) :: result when result: var
  def run(name, fun, fallback, opts \\ []) when is_list(opts) do
    case run(name, fun) do
      {:ok, result} ->
        result

      :failed ->
        record_discard(Keyword.get(opts, :discard))
        fallback
    end
  end

  @spec run(atom(), (-> result)) :: {:ok, result} | :failed when result: var
  def run(name, fun) when is_atom(name) and is_function(fun, 0) do
    {:ok, fun.()}
  catch
    kind, reason ->
      LoggerUtils.error(
        "#{inspect(name)} callback failed: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      :failed
  end

  @spec to_fun(atom(), spec(), [term()]) :: (-> term())
  def to_fun(name, spec, args) when is_atom(name) and is_list(args) do
    case spec do
      fun when is_function(fun, length(args)) ->
        fn -> apply(fun, args) end

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        fn -> apply(mod, fun, args) end

      other ->
        raise ArgumentError,
              "#{inspect(name)} must be an anonymous function or a {module, function} tuple, " <>
                "got: #{inspect(other)}"
    end
  end

  defp record_discard(nil), do: :ok

  defp record_discard({reason, event_or_data_category}) do
    _ = ClientReport.Sender.record_discarded_events(reason, event_or_data_category)
    :ok
  end
end
