defmodule PhoenixAppWeb.Schema do
  use Absinthe.Schema

  query do
    field :health, :string do
      resolve(fn _, _, _ -> {:ok, "ok"} end)
    end
  end

  mutation do
    @desc "Schedule an Oban job via GraphQL"
    field :schedule_job, :schedule_job_result do
      arg(:payload, non_null(:string))

      resolve(&PhoenixAppWeb.Resolvers.Jobs.schedule_job/3)
    end
  end

  object :schedule_job_result do
    field :job_id, non_null(:integer)
    field :worker, non_null(:string)
    field :queue, non_null(:string)
    field :payload, non_null(:string)
    field :enqueued, non_null(:boolean)
  end
end
