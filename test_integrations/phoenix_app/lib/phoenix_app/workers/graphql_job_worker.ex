defmodule PhoenixApp.Workers.GraphQLJobWorker do
  use Oban.Worker, queue: :default

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"payload" => payload}}) do
    Logger.info("GraphQLJobWorker processing job", payload: payload)
    :ok
  end

  def perform(%Oban.Job{}) do
    Logger.info("GraphQLJobWorker processing job with no payload")
    :ok
  end
end
