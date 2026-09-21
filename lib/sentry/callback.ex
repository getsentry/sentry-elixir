defmodule Sentry.Callback do
  @moduledoc false

  alias Sentry.ClientReport
  alias Sentry.LoggerUtils

  @type spec() :: (... -> term()) | {module(), atom()} | {module(), atom(), [term()]}

  @spec run(atom(), (-> result), result, keyword()) :: result when result: var
  def run(name, fun, fallback, opts \\ []) when is_list(opts) do
    case guard(describe_failure(name, Keyword.get(opts, :context)), fun) do
      {:ok, result} ->
        result

      :failed ->
        record_discard(Keyword.get(opts, :discard))
        fallback
    end
  end

  @spec run(atom(), (-> result)) :: {:ok, result} | :failed when result: var
  def run(name, fun) when is_atom(name) do
    guard(describe_failure(name, nil), fun)
  end

  @spec guard(String.t(), (-> result)) :: {:ok, result} | :failed when result: var
  def guard(description, fun) when is_binary(description) and is_function(fun, 0) do
    {:ok, fun.()}
  catch
    kind, reason ->
      LoggerUtils.error(description <> ": " <> Exception.format(kind, reason, __STACKTRACE__))

      :failed
  end

  @spec to_fun(atom(), spec(), [term()]) :: (-> term())
  def to_fun(name, spec, args) when is_atom(name) and is_list(args) do
    case spec do
      fun when is_function(fun, length(args)) ->
        fn -> apply(fun, args) end

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        fn -> apply(mod, fun, args) end

      {mod, fun, extra_args} when is_atom(mod) and is_atom(fun) and is_list(extra_args) ->
        fn -> apply(mod, fun, args ++ extra_args) end

      other ->
        raise ArgumentError,
              "#{inspect(name)} must be an anonymous function or a {module, function} tuple, " <>
                "got: #{inspect(other)}"
    end
  end

  @spec validate(atom(), value, (value -> as_boolean(term())), String.t()) ::
          {:ok, value} | :invalid
        when value: var
  def validate(name, value, validator, expected)
      when is_atom(name) and is_function(validator, 1) and is_binary(expected) do
    if validator.(value) do
      {:ok, value}
    else
      LoggerUtils.warning(
        "#{inspect(name)} callback returned an invalid value: " <>
          "expected #{expected}, got: #{inspect(value)}"
      )

      :invalid
    end
  end

  defp record_discard(nil), do: :ok

  defp record_discard({reason, event_or_data_category}) do
    _ = ClientReport.Sender.record_discarded_events(reason, event_or_data_category)
    :ok
  end

  defp describe_failure(name, nil), do: "#{inspect(name)} callback failed"
  defp describe_failure(name, context), do: "#{inspect(name)} callback failed #{context}"
end
