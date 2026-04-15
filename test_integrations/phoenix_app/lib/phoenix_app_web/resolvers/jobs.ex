defmodule PhoenixAppWeb.Resolvers.Jobs do
  alias PhoenixApp.Workers.GraphQLJobWorker

  def schedule_job(_parent, %{payload: payload}, _resolution) do
    {:ok, job} =
      %{"payload" => payload}
      |> GraphQLJobWorker.new()
      |> OpentelemetryOban.insert()

    {:ok,
     %{
       job_id: job.id,
       worker: job.worker,
       queue: job.queue,
       payload: payload,
       enqueued: true
     }}
  end
end
