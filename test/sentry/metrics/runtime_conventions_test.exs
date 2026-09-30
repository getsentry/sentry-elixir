defmodule Sentry.Metrics.RuntimeConventionsTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.Metrics.Runtime
  alias Sentry.Test, as: SentryTest

  @namespace "elixir"
  @definitions Path.expand("../../fixtures/sentry_conventions", __DIR__)

  setup do
    SentryTest.setup_sentry()
    :ok = Runtime.attach(version_attributes: true)
    on_exit(&Runtime.detach/0)
    %{metrics: emit_all_runtime_metrics()}
  end

  test "every emitted runtime metric has a conventions definition", %{metrics: metrics} do
    missing =
      for name <- metric_names(metrics),
          not File.exists?(metric_definition_path(name)),
          do: name

    assert missing == []
  end

  test "every definition in the elixir namespace is emitted", %{metrics: metrics} do
    defined = namespace_definitions() |> Enum.map(& &1["key"]) |> Enum.sort()

    assert defined -- metric_names(metrics) == []
  end

  test "emitted type and unit match the definition", %{metrics: metrics} do
    mismatches =
      for metric <- metrics,
          definition = read_metric_definition(metric.name),
          definition != nil,
          {to_string(metric.type), metric.unit} !=
            {definition["instrument"], definition["unit"]},
          uniq: true,
          do:
            {metric.name,
             sdk: {to_string(metric.type), metric.unit},
             conventions: {definition["instrument"], definition["unit"]}}

    assert mismatches == []
  end

  test "breakdown attributes are declared by the definition and present on every point", %{
    metrics: metrics
  } do
    mismatches =
      for {name, points} <- Enum.group_by(metrics, & &1.name),
          definition = read_metric_definition(name),
          definition != nil,
          declared = Enum.sort(definition["attributes"] || []),
          point <- points,
          emitted = namespace_attribute_keys(point),
          emitted != declared,
          uniq: true,
          do: {name, sdk: emitted, conventions: declared}

    assert mismatches == []
  end

  @tag :conventions
  test "every emitted attribute is registered in sentry-conventions and not deprecated", %{
    metrics: metrics
  } do
    conventions = conventions_path!()
    keys = metrics |> Enum.flat_map(&Map.keys(&1.attributes)) |> Enum.uniq() |> Enum.sort()

    problems =
      for key <- keys,
          problem = attribute_problem(conventions, key),
          problem != nil,
          do: {key, problem}

    assert problems == []
  end

  defp emit_all_runtime_metrics do
    :telemetry.execute(
      [:vm, :memory],
      %{total: 100_000, processes: 40_000, atom: 1_000, binary: 5_000, code: 20_000, ets: 3_000},
      %{}
    )

    :telemetry.execute([:vm, :total_run_queue_lengths], %{total: 7, cpu: 5, io: 2}, %{})

    :telemetry.execute(
      [:vm, :system_counts],
      %{
        process_count: 100,
        process_limit: 1_000,
        atom_count: 50,
        atom_limit: 500,
        port_count: 4,
        port_limit: 200
      },
      %{}
    )

    :ok = Runtime.dispatch_scheduler_utilization()
    :ok = Runtime.dispatch_scheduler_utilization()

    flush_telemetry_processor()

    metrics = SentryTest.pop_sentry_metrics()
    refute metrics == []
    metrics
  end

  defp conventions_path! do
    case System.get_env("SENTRY_CONVENTIONS_PATH") do
      nil -> flunk("SENTRY_CONVENTIONS_PATH must point at a sentry-conventions checkout")
      path -> Path.expand(path)
    end
  end

  defp metric_names(metrics), do: metrics |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

  defp namespace_attribute_keys(point) do
    point.attributes
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, @namespace <> "."))
    |> Enum.sort()
  end

  defp namespace_definitions do
    @definitions
    |> Path.join("model/metrics/#{@namespace}/*.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
  end

  defp read_metric_definition(name) do
    path = metric_definition_path(name)
    if File.exists?(path), do: path |> File.read!() |> Jason.decode!()
  end

  defp metric_definition_path(name) do
    Path.join([@definitions, "model/metrics", namespace_of(name), file_name(name)])
  end

  defp attribute_problem(conventions, key) do
    path = Enum.find(attribute_paths(conventions, key), &File.exists?/1)

    cond do
      path == nil -> :not_registered
      get_in(Jason.decode!(File.read!(path)), ["deprecation"]) != nil -> :deprecated
      true -> nil
    end
  end

  defp attribute_paths(conventions, key) do
    for root <- [@definitions, conventions] do
      Path.join([root, "model/attributes", namespace_of(key), file_name(key)])
    end
  end

  defp namespace_of(key) do
    case String.split(key, ".", parts: 2) do
      [namespace, _rest] -> namespace
      [_single] -> ""
    end
  end

  defp file_name(key), do: String.replace(key, ".", "__") <> ".json"
end
