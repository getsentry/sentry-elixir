defmodule Sentry.Callback do
  @moduledoc false

  alias Sentry.LoggerUtils

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
end
