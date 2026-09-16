defmodule Sentry.MetricSequenceTest do
  use Sentry.Case, async: false

  alias Sentry.Metric

  setup do
    Metric.init_sequence()
    :ok
  end

  test "starts at 0 and increments by 1 for every metric captured" do
    assert sequence_of(build(:counter)) == 0
    assert sequence_of(build(:gauge)) == 1
    assert sequence_of(build(:distribution)) == 2
  end

  test "cannot be overridden by a user-supplied attribute" do
    assert sequence_of(build(:counter, %{"sentry.timestamp.sequence" => 999})) == 0
  end

  defp build(type, attributes \\ %{}) do
    %Metric{
      type: type,
      name: "test.#{type}",
      value: 1,
      timestamp: 1_234_567_890.0,
      attributes: attributes
    }
  end

  defp sequence_of(metric) do
    metric
    |> Metric.attach_default_attributes()
    |> Map.fetch!(:attributes)
    |> Map.fetch!("sentry.timestamp.sequence")
  end
end
