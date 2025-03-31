defmodule Sentry.Opentelemetry.SamplerTest do
  use Sentry.Case, async: true

  alias Sentry.OpenTelemetry.Sampler

  test "drops spans with the given name" do
    assert {:drop, [], []} =
             Sampler.should_sample(nil, nil, nil, "Elixir.Oban.Stager process", nil, nil,
               drop: ["Elixir.Oban.Stager process"]
             )
  end

  test "records and samples spans with the given name" do
    assert {:record_and_sample, [], []} =
             Sampler.should_sample(nil, nil, nil, "Elixir.Oban.Worker process", nil, nil,
               drop: []
             )
  end
end
