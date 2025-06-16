defmodule PhoenixApp.Workers.TestWorker do
  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sleep_time" => sleep_time, "should_fail" => should_fail}}) do
    # Simulate some work
    Process.sleep(sleep_time)

    if should_fail do
      raise "Simulated failure in test worker"
    else
      :ok
    end
  end

  def perform(%Oban.Job{args: %{"sleep_time" => sleep_time}}) do
    # Simulate some work
    Process.sleep(sleep_time)
    :ok
  end
end
