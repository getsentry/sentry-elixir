if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
  defmodule Sentry.OpenTelemetry.DynamicSamplingContext do
    @moduledoc false
    # The dynamic sampling context (DSC) a transaction envelope carries in its
    # `trace` header, so that Sentry can extrapolate counts from the client
    # sample rate and sample server-side consistently:
    # https://develop.sentry.dev/sdk/telemetry/traces/dynamic-sampling-context/

    alias Sentry.Config
    alias Sentry.OpenTelemetry.Sampler
    alias Sentry.OpenTelemetry.SpanRecord

    @type t :: %{optional(String.t()) => String.t()}

    @sentry_baggage_prefix "sentry-"

    @doc """
    The context of the trace this span record heads: the sampler's decision,
    read from the record's tracestate, and this SDK's identity.
    """
    @spec build(SpanRecord.t(), String.t()) :: t()
    def build(%SpanRecord{} = span_record, transaction_name) do
      decision = Sampler.decision(span_record.tracestate)

      %{
        "trace_id" => span_record.trace_id,
        "public_key" => public_key(),
        "sample_rate" => decision.sample_rate,
        "sample_rand" => decision.sample_rand,
        "sampled" => decision.sampled,
        "release" => Config.release(),
        "environment" => Config.environment_name(),
        "transaction" => transaction_name,
        "org_id" => Config.effective_org_id()
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end

    @doc """
    The context a continued trace arrived with in its `baggage` header, as it
    is ("frozen"): the `sentry-` members, percent-decoded, without their
    properties. `nil` when the baggage carries no Sentry context: a trace ID
    is the least one has, and this SDK's own propagator sends a baggage of
    only `sentry-org_id` when it heads a trace.
    """
    @spec from_baggage(String.t() | nil) :: t() | nil
    def from_baggage(nil), do: nil

    def from_baggage(baggage) when is_binary(baggage) do
      context =
        for member <- String.split(baggage, ","),
            [key, value] <- [String.split(member, "=", parts: 2)],
            @sentry_baggage_prefix <> name <- [String.trim(key)],
            name != "" and String.valid?(name),
            {:ok, decoded} <- [decode(value)],
            into: %{},
            do: {name, decoded}

      if Map.has_key?(context, "trace_id"), do: context
    end

    # The value comes from an untrusted header: one that is no UTF-8 after
    # percent-decoding, or no valid encoding at all (older Elixir raises), is
    # dropped rather than failing the encoding of the whole envelope.
    defp decode(value) do
      decoded = value |> String.split(";", parts: 2) |> hd() |> String.trim() |> URI.decode()
      if String.valid?(decoded), do: {:ok, decoded}, else: :error
    rescue
      ArgumentError -> :error
    end

    defp public_key do
      case Config.dsn() do
        %Sentry.DSN{public_key: public_key} -> public_key
        _no_dsn -> nil
      end
    end
  end
end
