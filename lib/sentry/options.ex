defmodule Sentry.Options do
  @moduledoc """
  A module to store and document globally available options.
  """

  # The docs for the options here are generated in the Sentry module, so you can refer to types
  # and functions and so on like if you were writing these docs in the Sentry module itself.
  send_event_opts_schema = [
    result: [
      type: {:in, [:sync, :none]},
      doc: """
      Allows specifying how the result should be returned. The possible values are:

      * `:sync` - Sentry will make an API call synchronously (including retries) and will
        return `{:ok, event_id}` if successful.

      * `:none` - Sentry will send the event in the background, in a *fire-and-forget*
        fashion. The function will return `{:ok, ""}` regardless of whether the API
        call ends up being successful or not.
      """
    ],
    sample_rate: [
      type: :float,
      doc: """
      Same as the global `:sample_rate` configuration, but applied only to
      this call. See the module documentation. *Available since v10.0.0*.
      """
    ],
    before_send: [
      type: {:or, [{:fun, 1}, {:tuple, [:atom, :atom]}]},
      type_doc: "`t:before_send_event_callback/0`",
      doc: """
      Same as the global `:before_send` configuration, but
      applied only to this call. See the module documentation. *Available since v10.0.0*.
      """
    ],
    after_send_event: [
      type: {:or, [{:fun, 2}, {:tuple, [:atom, :atom]}]},
      type_doc: "`t:after_send_event_callback/1`",
      doc: """
      Same as the global `:after_send_event` configuration, but
      applied only to this call. See the module documentation. *Available since v10.0.0*.
      """
    ],
    client: [
      type: :atom,
      type_doc: "`t:module/0`",
      doc: """
      Same as the global `:client` configuration, but
      applied only to this call. See the module documentation. *Available since v10.0.0*.
      """
    ],

    # Private options, only used in testing.
    request_retries: [
      type: {:list, :integer},
      doc: false
    ]
  ]

  create_event_opts_schema = [
    exception: [
      type: {:custom, Sentry.Event, :__validate_exception__, [:exception]},
      type_doc: "`t:Exception.t/0`",
      doc: """
      This is the exception that gets reported in the
      `:exception` field of `t:t/0`. The term passed here also ends up unchanged in the
      `:original_exception` field of `t:t/0`. This option is **required** unless the
      `:message` option is present. Not present by default.
      """
    ],
    stacktrace: [
      type:
        {:list,
         {:or,
          [
            {:tuple, [:atom, :atom, :any, :keyword_list]},
            {:tuple, [:any, :any, :keyword_list]}
          ]}},
      type_doc: "`t:Exception.stacktrace/0`",
      doc: """
      The exception's stacktrace. This can also be used with messages (`:message`). Not
      present by default.
      """
    ],
    message: [
      type: :string,
      doc: """
      A message to report. The string can contain interpolation markers (`%s`). In that
      case, you can pass the `:interpolation_parameters` option as well to fill
      in those parameters. See `Sentry.capture_message/2` for more information on
      message interpolation. Not present by default.
      """
    ],
    extra: [
      type: {:map, {:or, [:atom, :string]}, :any},
      type_doc: "`t:Sentry.Context.extra/0`",
      default: %{},
      doc: """
      Map of extra context, which gets merged with the current context
      (see `Sentry.Context.set_extra_context/1`). If fields collide, the ones
      in the map passed through this option have precedence over the ones in
      the context.
      """
    ],
    user: [
      type: :map,
      type_doc: "`t:Sentry.Context.user_context/0`",
      default: %{},
      doc: """
      Map of user context, which gets merged with the current context
      (see `Sentry.Context.set_user_context/1`). If fields collide, the ones
      in the map passed through this option have precedence over the ones in
      the context.
      """
    ],
    tags: [
      type: {:map, {:or, [:atom, :string]}, :any},
      type_doc: "`t:Sentry.Context.tags/0`",
      default: %{},
      doc: """
      Map of tags context, which gets merged with the current context (see
      `Sentry.Context.set_tags_context/1`) and with the `:tags` option in the global
      Sentry configuration. If fields collide, the ones in the map passed through
      this option have precedence over the ones in the context, which have precedence
      over the ones in the configuration.
      """
    ],
    request: [
      type: :map,
      type_doc: "`t:Sentry.Context.request_context/0`",
      default: %{},
      doc: """
      Map of request context, which gets merged with the current context
      (see `Sentry.Context.set_request_context/1`). If fields collide, the ones
      in the map passed through this option have precedence over the ones in
      the context.
      """
    ],
    breadcrumbs: [
      type: {:list, {:or, [:keyword_list, :map]}},
      type_doc: "list of `t:keyword/0` or `t:Sentry.Context.breadcrumb/0`",
      default: [],
      doc: """
      List of breadcrumbs. This list gets **prepended** to the list
      in the context (see `Sentry.Context.add_breadcrumb/1`).
      """
    ],
    level: [
      type: {:in, [:fatal, :error, :warning, :info, :debug]},
      type_doc: "`t:level/0`",
      default: :error,
      doc: """
      The level of the event.
      """
    ],
    fingerprint: [
      type: {:list, :string},
      default: ["{{ default }}"],
      doc: """
      List of the fingerprint for grouping this event.
      """
    ],
    event_source: [
      type: :atom,
      doc: """
      The source of the event. This fills in the `:source` field of the
      returned struct. This is not present by default.
      """
    ],
    interpolation_parameters: [
      type: {:list, :any},
      doc: """
      The parameters to use for message interpolation. This is only used if the
      `:message` option is present. This is not present by default. See
      `Sentry.capture_message/2`. *Available since v10.1.0*.
      """
    ],
    integration_meta: [
      type: :map,
      default: %{},
      doc: false
    ],

    ## Internal options
    handled: [
      type: :boolean,
      default: true,
      doc: false
    ]
  ]

  @send_event_opts_schema NimbleOptions.new!(send_event_opts_schema)
  @send_event_opts_keys Keyword.keys(send_event_opts_schema)

  @create_event_opts_schema NimbleOptions.new!(create_event_opts_schema)

  @spec get_client_options() :: NimbleOptions.t()
  def get_client_options do
    @send_event_opts_schema
  end

  @spec get_client_options_keys() :: list(atom())
  def get_client_options_keys do
    @send_event_opts_keys
  end

  @spec get_event_options() :: NimbleOptions.t()
  def get_event_options do
    @create_event_opts_schema
  end

  @spec validate_options!(keyword(), NimbleOptions.t()) :: keyword()
  def validate_options!(opts, schema) when is_list(opts) do
    NimbleOptions.validate!(opts, schema)
  end
end
