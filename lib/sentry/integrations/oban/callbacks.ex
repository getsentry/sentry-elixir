defmodule Sentry.Integrations.Oban.Callbacks do
  @moduledoc false

  alias Sentry.Callback
  alias Sentry.LoggerUtils

  @spec should_report?(keyword(), atom(), struct()) :: boolean()
  def should_report?(config, option, job) when is_list(config) and is_atom(option) do
    case Keyword.get(config, option) do
      callback when is_function(callback, 2) ->
        worker = resolve_worker(job)

        Callback.run(
          option,
          fn -> callback.(worker, job) == true end,
          true,
          context: describe_target(worker, job)
        )

      _ ->
        true
    end
  end

  @spec describe_target(term(), struct()) :: String.t()
  def describe_target(worker, job) do
    "for worker #{inspect(worker)} (job ID #{inspect(job.id)})"
  end

  defp resolve_worker(job) do
    case apply(Oban.Worker, :from_string, [job.worker]) do
      {:ok, mod} ->
        mod

      {:error, _} ->
        LoggerUtils.warning(
          "Could not resolve Oban worker module from string: #{inspect(job.worker)}"
        )

        nil
    end
  end
end
