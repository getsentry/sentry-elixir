defmodule SamplingContext do
  @moduledoc """
  The struct for the **sampling_context** that is passed to `traces_sampler`.

  This is set up via `Sentry.OpenTelemetry.Sampler`.

  See also <https://develop.sentry.dev/sdk/telemetry/traces/#sampling-context>.
  """

  @moduledoc since: "11.0.0"

  @typedoc """
  The sampling context struct that contains information needed for sampling decisions.

  This matches the structure used in the Python SDK's create_sampling_context function.
  """
  @type t :: %__MODULE__{
          transaction_context: %{
            name: String.t() | nil,
            op: String.t(),
            trace_id: String.t(),
            attributes: map()
          },
          parent_sampled: boolean() | nil
        }

  @enforce_keys [:transaction_context, :parent_sampled]
  defstruct [:transaction_context, :parent_sampled]

  @behaviour Access

  @impl Access
  def fetch(struct, key) do
    case Map.fetch(struct, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  @impl Access
  def get_and_update(struct, key, function) do
    current_value = Map.get(struct, key)

    case function.(current_value) do
      {get_value, update_value} ->
        {get_value, Map.put(struct, key, update_value)}

      :pop ->
        {current_value, Map.delete(struct, key)}
    end
  end

  @impl Access
  def pop(struct, key) do
    {Map.get(struct, key), Map.delete(struct, key)}
  end
end
