defmodule PhoenixAppWeb.TestWorkerLive do
  use PhoenixAppWeb, :live_view

  alias PhoenixApp.Workers.TestWorker

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        form: to_form(%{"sleep_time" => 1000, "should_fail" => false, "queue" => "default"}),
        auto_form: to_form(%{"job_count" => 5}),
        jobs: list_jobs()
      )

    if connected?(socket) do
      # Poll for job updates every second
      :timer.send_interval(1000, self(), :update_jobs)
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("schedule", %{"test_job" => params}, socket) do
    sleep_time = String.to_integer(params["sleep_time"])
    should_fail = params["should_fail"] == "true"
    queue = params["queue"]

    case schedule_job(sleep_time, should_fail, queue) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job scheduled successfully!")
         |> assign(jobs: list_jobs())}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error scheduling job: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("auto_schedule", %{"auto" => %{"job_count" => count}}, socket) do
    job_count = String.to_integer(count)

    results =
      Enum.map(1..job_count, fn _ ->
        sleep_time = Enum.random(500..5000)
        should_fail = Enum.random([true, false])
        queue = Enum.random(["default", "background"])

        schedule_job(sleep_time, should_fail, queue)
      end)

    failed_count = Enum.count(results, &match?({:error, _}, &1))
    success_count = job_count - failed_count

    socket =
      socket
      |> put_flash(:info, "Scheduled #{success_count} jobs successfully!")
      |> assign(jobs: list_jobs())

    if failed_count > 0 do
      socket = put_flash(socket, :error, "Failed to schedule #{failed_count} jobs")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:update_jobs, socket) do
    {:noreply, assign(socket, jobs: list_jobs())}
  end

  defp schedule_job(sleep_time, should_fail, queue) do
    TestWorker.new(
      %{"sleep_time" => sleep_time, "should_fail" => should_fail},
      queue: queue
    )
    |> Oban.insert()
  end

  defp list_jobs do
    import Ecto.Query

    Oban.Job
    |> where([j], j.worker == "PhoenixApp.Workers.TestWorker")
    |> order_by([j], desc: j.inserted_at)
    |> limit(10)
    |> PhoenixApp.Repo.all()
  end
end
