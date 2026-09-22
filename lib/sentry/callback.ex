defmodule Sentry.Callback do
  @moduledoc false

  alias Sentry.LoggerUtils

  @type spec() :: (... -> term()) | {module(), atom()}

  @spec run(atom(), (-> result), result) :: result when result: var
  def run(name, fun, fallback) when is_atom(name) and is_function(fun, 0) do
    fun.()
  catch
    kind, reason ->
      LoggerUtils.error(
        "#{inspect(name)} callback failed: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      fallback
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
end
