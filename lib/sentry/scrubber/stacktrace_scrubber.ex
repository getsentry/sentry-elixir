defmodule Sentry.Scrubber.StacktraceScrubber do
  @moduledoc false

  # Scrubs args captured into error data — a stacktrace frame's args (see
  # `Sentry.Event`) or an exception's `:args` field (see `Sentry.PlugCapture`).
  #
  # A `%Plug.Conn{}` and any non-struct term are scrubbed with
  # `Sentry.Scrubber.scrub/1`. Any other struct has its fields scrubbed but keeps
  # its type: these args are rendered with `inspect/2`, so a scrubbed `%Mod{...}`
  # is far more useful in a frame var than the bare map `Sentry.Scrubber.scrub/1`
  # would produce (that map shape is right for the JSON request payload, but
  # garbles structs when inspected). This module is framework-agnostic and makes
  # no assumptions about the relationships between args; a caller that knows more
  # can pass its own args-scrubber callback to `scrub/2` — for example
  # `Sentry.PlugCapture`, which knows a `Phoenix.ActionClauseError` carries
  # `[conn, conn.params]` and mirrors the scrubbed conn's params onto the params arg.

  @doc """
  Scrubs a list of args, redacting each element.

  A `%Plug.Conn{}` and any non-struct term go through `Sentry.Scrubber.scrub/1`.
  Any other struct has its fields scrubbed while keeping its type, so it inspects
  as a scrubbed `%Mod{...}` rather than a bare map in the frame var.
  """
  @spec scrub_args([term()]) :: [term()]
  def scrub_args(args) when is_list(args), do: Enum.map(args, &scrub_arg/1)

  defp scrub_arg(conn) when is_struct(conn, Plug.Conn), do: Sentry.Scrubber.scrub(conn)

  defp scrub_arg(struct) when is_struct(struct),
    do: struct(struct, struct |> Map.from_struct() |> Sentry.Scrubber.scrub())

  defp scrub_arg(other), do: Sentry.Scrubber.scrub(other)

  @doc """
  Scrubs an exception's `:args` and returns the updated exception.

  `args_scrubber` is a 1-arity function applied to the exception's args list; it
  defaults to `scrub_args/1`. Callers that know the args' shape can pass a custom
  callback. Exceptions without a list `:args` field are returned unchanged.
  """
  @spec scrub(Exception.t(), ([term()] -> [term()])) :: Exception.t()
  def scrub(exception, args_scrubber \\ &scrub_args/1) do
    case exception do
      %{args: args} when is_list(args) -> %{exception | args: args_scrubber.(args)}
      _ -> exception
    end
  end
end
