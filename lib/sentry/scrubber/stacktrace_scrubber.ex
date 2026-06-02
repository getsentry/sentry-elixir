defmodule Sentry.Scrubber.StacktraceScrubber do
  @moduledoc false

  # Scrubs args captured into error data — a stacktrace frame's args (see
  # `Sentry.Event`) or an exception's `:args` field (see `Sentry.PlugCapture`).
  #
  # Each arg is scrubbed with `Sentry.Scrubber.scrub/1` by default. This module is
  # framework-agnostic and makes no assumptions about the shape of the args; a
  # caller that knows more about them (their relationships, or a custom scrubber)
  # can pass its own args-scrubber callback to `scrub/2` — for example
  # `Sentry.PlugCapture`, which knows a `Phoenix.ActionClauseError` carries
  # `[conn, conn.params]` and mirrors the scrubbed conn's params onto the params arg.

  @doc """
  Scrubs a list of args, redacting each element with `Sentry.Scrubber.scrub/1`.
  """
  @spec scrub_args([term()]) :: [term()]
  def scrub_args(args) when is_list(args), do: Enum.map(args, &Sentry.Scrubber.scrub/1)

  @doc """
  Scrubs an exception's `:args` and returns the updated exception.

  `args_scrubber` is a 1-arity function applied to the exception's args list; it
  defaults to `scrub_args/1` (per-arg `Sentry.Scrubber.scrub/1`). Callers that know
  the args' shape can pass a custom callback. Exceptions without a list `:args`
  field are returned unchanged.
  """
  @spec scrub(Exception.t(), ([term()] -> [term()])) :: Exception.t()
  def scrub(exception, args_scrubber \\ &scrub_args/1) do
    case exception do
      %{args: args} when is_list(args) -> %{exception | args: args_scrubber.(args)}
      _ -> exception
    end
  end
end
