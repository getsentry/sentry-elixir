defmodule Sentry.CheckIn do
  @moduledoc """
  This module represents the struct for a "check-in".

  Check-ins are used to report the status of a monitor to Sentry. This is used
  to track the health and progress of **cron jobs**. This module is somewhat
  low level, and mostly useful when you want to report the status of a cron
  but you are not using any common library to manage your cron jobs.

  > #### Using `capture_check_in/1` {: .tip}
  >
  > Instead of using this module directly, you'll probably want to use
  > `Sentry.capture_check_in/1` to manually report the status of your cron jobs.

  See <https://develop.sentry.dev/sdk/check-ins/>. This struct is available
  since v10.2.0.
  """
  @moduledoc since: "10.2.0"

  alias Sentry.{Config, Interfaces, UUID}

  @typedoc """
  The possible status of the check-in.
  """
  @type status() :: :in_progress | :ok | :error

  @typedoc """
  The possible values for the `:schedule` option under `:monitor_config`.

  If the `:type` is `:crontab`, then the `:value` must be a string representing
  a crontab expression. If the `:type` is `:interval`, then the `:value` must be
  a number representing the interval and the `:unit` must be present and be one of `:year`,
  `:month`, `:week`, `:day`, `:hour`, or `:minute`.
  """
  @type monitor_config_schedule() ::
          %{type: :crontab, value: String.t()}
          | %{
              type: :interval,
              value: number(),
              unit: :year | :month | :week | :day | :hour | :minute
            }

  @typedoc """
  The type for the check-in struct.
  """
  @type t() :: %__MODULE__{
          check_in_id: String.t(),
          monitor_slug: String.t(),
          status: status(),
          duration: float() | nil,
          release: String.t() | nil,
          environment: String.t() | nil,
          monitor_config:
            nil
            | %{
                required(:schedule) => monitor_config_schedule(),
                optional(:checkin_margin) => number(),
                optional(:max_runtime) => number(),
                optional(:failure_issue_threshold) => number(),
                optional(:recovery_threshold) => number(),
                optional(:timezone) => String.t()
              },
          contexts: Interfaces.context()
        }

  @enforce_keys [
    :check_in_id,
    :monitor_slug,
    :status
  ]
  defstruct @enforce_keys ++
              [
                :duration,
                :release,
                :environment,
                :monitor_config,
                :contexts
              ]

  number_schema_opts = [type: {:or, [:integer, :float]}, type_doc: "`t:number/0`"]

  crontab_schedule_opts_schema = [
    type: [type: {:in, [:crontab]}, required: true],
    value: [type: :string, required: true]
  ]

  interval_schedule_opts_schema = [
    type: [type: {:in, [:interval]}, required: true],
    value: number_schema_opts,
    unit: [type: {:in, [:year, :month, :week, :day, :hour, :minute]}, required: true]
  ]

  create_check_in_opts_schema = [
    check_in_id: [
      type: :string
    ],
    status: [
      type: {:in, [:in_progress, :ok, :error]},
      required: true,
      type_doc: "`t:status/0`"
    ],
    monitor_slug: [
      type: :string,
      required: true
    ],
    duration: number_schema_opts,
    contexts: [
      type: :map,
      default: %{},
      doc: """
      The contexts to attach to the check-in. This is a map of arbitrary data,
      but right now Sentry supports the `trace_id` key under the
      [trace context](https://develop.sentry.dev/sdk/event-payloads/contexts/#trace-context)
      to connect the check-in with related errors.
      """
    ],
    monitor_config: [
      doc: "If you pass this optional option, you **must** pass the nested `:schedule` option.",
      type: :keyword_list,
      keys: [
        checkin_margin: number_schema_opts,
        max_runtime: number_schema_opts,
        failure_issue_threshold: number_schema_opts,
        recovery_threshold: number_schema_opts,
        timezone: [type: :string],
        schedule: [
          type:
            {:or,
             [
               {:keyword_list, crontab_schedule_opts_schema},
               {:keyword_list, interval_schedule_opts_schema}
             ]},
          type_doc: "`t:monitor_config_schedule/0`"
        ]
      ]
    ]
  ]

  @create_check_in_opts_schema NimbleOptions.new!(create_check_in_opts_schema)

  @doc """
  Creates a new check-in struct with the given options.

  ## Options

  The options you can pass match a subset of the fields of the `t:t/0` struct.
  You can pass:

  #{NimbleOptions.docs(@create_check_in_opts_schema)}

  ## Examples

      iex> check_in = CheckIn.new(status: :ok, monitor_slug: "my-slug")
      iex> check_in.status
      :ok
      iex> check_in.monitor_slug
      "my-slug"

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts = NimbleOptions.validate!(opts, @create_check_in_opts_schema)

    monitor_config =
      case Keyword.fetch(opts, :monitor_config) do
        {:ok, monitor_config} ->
          monitor_config
          |> Map.new()
          |> Map.update!(:schedule, &Map.new/1)

        :error ->
          nil
      end

    %__MODULE__{
      check_in_id: Keyword.get_lazy(opts, :check_in_id, &UUID.uuid4_hex/0),
      status: Keyword.fetch!(opts, :status),
      monitor_slug: Keyword.fetch!(opts, :monitor_slug),
      duration: Keyword.get(opts, :duration),
      release: Config.release(),
      environment: Config.environment_name(),
      monitor_config: monitor_config,
      contexts: Keyword.fetch!(opts, :contexts)
    }
  end

  # Used to then encode the returned map to JSON.
  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = check_in) do
    Map.from_struct(check_in)
  end
end
