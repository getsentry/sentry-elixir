defmodule Sentry.Interfaces do
  @moduledoc """
  Top-level module for Sentry interfaces.

  Interfaces are pieces of the event payload that include various kinds of information.
  See the [event payloads documentation](https://develop.sentry.dev/sdk/event-payloads/)
  and its subsections.

  The types in this module and the nested structs are taken from Sentry's
  [JSONSchema definitions](https://github.com/getsentry/sentry-data-schemas/blob/ebc77d3cb2f3ef288913cce80a292ca0389a08e7/relay/event.schema.json).
  """

  @typedoc """
  The **user** interface.

  This interface is not a *struct* since it allows any additional arbitrary key
  other than the ones defined in the schema.

  See <https://develop.sentry.dev/sdk/event-payloads/user>.
  """
  @typedoc since: "9.0.0"
  @type user() :: %{
          optional(:id) => term(),
          optional(:username) => term(),
          optional(:email) => String.t() | nil,
          optional(:ip_address) => String.t() | nil,
          optional(:segment) => term(),
          optional(:geo) => %{
            optional(:city) => String.t() | nil,
            optional(:country_code) => String.t() | nil,
            optional(:region) => String.t() | nil
          },
          optional(atom()) => term()
        }

  @typedoc """
  The generic **context** interface.

  See <https://develop.sentry.dev/sdk/event-payloads/contexts>.
  """
  @typedoc since: "9.0.0"
  @type context() :: map()

  defmodule Request do
    @moduledoc """
    The struct for the **request** interface.

    See <https://develop.sentry.dev/sdk/event-payloads/request>.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            method: String.t() | nil,
            url: String.t() | nil,
            query_string: String.t() | map() | [{String.t(), String.t()}] | nil,
            data: term(),
            cookies: String.t() | map() | [{String.t(), String.t()}] | nil,
            headers: map() | nil,
            env: map() | nil
          }

    defstruct [
      :method,
      :url,
      :query_string,
      :data,
      :cookies,
      :headers,
      :env
    ]
  end

  defmodule SDK do
    @moduledoc """
    The struct for the **SDK** interface.

    This is usually filled in by the SDK itself.

    See <https://develop.sentry.dev/sdk/event-payloads/sdk>.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            name: String.t(),
            version: String.t()
          }

    @enforce_keys [:name, :version]
    defstruct [:name, :version]
  end

  defmodule Message do
    @moduledoc """
    The struct for the **message** interface.

    See <https://develop.sentry.dev/sdk/event-payloads/message>.
    """

    @moduledoc since: "10.1.0"

    @typedoc since: "10.1.0"
    @type t() :: %__MODULE__{
            message: String.t(),
            formatted: String.t(),
            params: [term()]
          }

    @enforce_keys [:formatted]
    defstruct [:message, :params, :formatted]
  end

  defmodule Exception.Mechanism do
    @moduledoc """
    The struct for the **exception mechanism** to be used within exceptions.

    See `Sentry.Interfaces.Exception`.
    """

    @moduledoc since: "10.2.0"

    @typedoc since: "10.2.0"
    @type t() :: %__MODULE__{
            type: String.t(),
            handled: boolean() | nil,
            data: map() | nil,
            synthetic: boolean() | nil,
            help_link: String.t() | nil,
            meta: map() | nil
          }

    defstruct [:handled, :data, :synthetic, :help_link, :meta, type: "generic"]
  end

  defmodule Exception do
    @moduledoc """
    The struct for the **exception** interface.

    See <https://develop.sentry.dev/sdk/event-payloads/exception>.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            type: String.t(),
            value: String.t(),
            module: String.t() | nil,
            stacktrace: Sentry.Interfaces.Stacktrace.t() | nil,
            mechanism: Sentry.Interfaces.Exception.Mechanism.t() | nil
          }

    @enforce_keys [:type, :value]
    defstruct [:type, :value, :module, :stacktrace, :mechanism]
  end

  defmodule Stacktrace.Frame do
    @moduledoc """
    The struct for the **stacktrace frame** to be used within exceptions.

    See `Sentry.Interfaces.Stacktrace`.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            module: module() | nil,
            filename: Path.t() | nil,
            function: String.t(),
            lineno: pos_integer() | nil,
            colno: pos_integer() | nil,
            in_app: boolean(),
            vars: map() | nil,
            context_line: String.t() | nil,
            pre_context: [String.t()],
            post_context: [String.t()]
          }

    defstruct [
      :module,
      :function,
      :filename,
      :lineno,
      :colno,
      :in_app,
      :vars,
      :context_line,
      pre_context: [],
      post_context: []
    ]
  end

  defmodule Stacktrace do
    @moduledoc """
    The struct for the **stacktrace** interface.

    See <https://develop.sentry.dev/sdk/event-payloads/stacktrace>.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            frames: [Sentry.Interfaces.Stacktrace.Frame.t()]
          }

    @enforce_keys [:frames]
    defstruct [:frames]
  end

  defmodule Breadcrumb do
    @moduledoc """
    The struct for a single **breadcrumb** interface.

    See <https://develop.sentry.dev/sdk/event-payloads/breadcrumbs>.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            type: String.t(),
            category: String.t(),
            message: String.t(),
            data: term(),
            level: String.t() | nil,
            timestamp: String.t() | number()
          }

    defstruct [:type, :category, :message, :data, :level, :timestamp]
  end

  defmodule Thread do
    @moduledoc """
    The struct for the **thread** interface.

    See <https://develop.sentry.dev/sdk/event-payloads/threads>.
    """

    @moduledoc since: "10.1.0"

    @typedoc since: "10.1.0"
    @type t() :: %__MODULE__{
            id: term(),
            crashed: boolean() | nil,
            current: boolean() | nil,
            main: boolean() | nil,
            name: String.t() | nil,
            state: term(),
            held_locks: [term()],
            stacktrace: Sentry.Interfaces.Stacktrace.t() | nil
          }

    @enforce_keys [:id]
    defstruct [
      :id,
      :crashed,
      :current,
      :main,
      :name,
      :state,
      :held_locks,
      :stacktrace
    ]
  end
end
