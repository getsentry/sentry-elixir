defmodule Sentry.Payloads do
  @moduledoc false

  # The schemas in this module are taken from the Sentry documentation, but also
  # from the JSONSchema definitions at:
  # https://github.com/getsentry/sentry-data-schemas/blob/ebc77d3cb2f3ef288913cce80a292ca0389a08e7/relay/event.schema.json

  defmodule Event do
    @moduledoc """
    The struct for the top-level Sentry event payload.

    See <https://develop.sentry.dev/sdk/event-payloads>.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            # Required
            event_id: <<_::128>>,
            timestamp: String.t() | number(),
            platform: :elixir,

            # Optional
            level: :fatal | :error | :warning | :info | :debug | nil,
            logger: String.t() | nil,
            transaction: String.t() | nil,
            server_name: String.t() | nil,
            release: String.t() | nil,
            dist: String.t() | nil,
            tags: %{optional(String.t()) => String.t()},
            environment: String.t() | nil,
            modules: %{optional(String.t()) => String.t()},
            extra: map(),
            fingerprint: [String.t()],

            # Interfaces.
            breadcrumbs: [Sentry.Payloads.Breadcrumb.t()] | nil,
            exception: [Sentry.Payloads.Exception.t(), ...] | nil,
            request: Sentry.Payload.Request.t() | nil,
            sdk: Sentry.Payloads.SDK.t() | nil,
            user: Sentry.Payloads.User.t() | nil
          }

    @enforce_keys [:event_id, :timestamp]
    defstruct [
      # Required. Hexadecimal string representing a uuid4 value. The length is exactly 32
      # characters. Dashes are not allowed. Has to be lowercase.
      :event_id,

      # Required. Indicates when the event was created in the Sentry SDK. The format is either a
      # string as defined in RFC 3339 or a numeric (integer or float) value representing the number
      # of seconds that have elapsed since the Unix epoch.
      :timestamp,

      # Optional fields without defaults.
      :level,
      :logger,
      :transaction,
      :server_name,
      :release,
      :dist,

      # Interfaces.
      :breadcrumbs,
      :exception,
      :request,
      :sdk,
      :user,

      # Required. Has to be "elixir".
      platform: :elixir,

      # Optional fields with defaults.
      tags: %{},
      modules: %{},
      extra: %{},
      fingerprint: [],
      environment: "production"
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
            stacktrace: Sentry.Payloads.Stacktrace.t() | nil
          }

    @enforce_keys [:type, :value]
    defstruct [:type, :value, :module, :stacktrace]
  end

  defmodule Stacktrace.Frame do
    @moduledoc """
    The struct for the **stacktrace frame** to be used within exceptions.

    See `Sentry.Payloads.Stacktrace`.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            filename: Path.t(),
            function: String.t(),
            lineno: pos_integer(),
            colno: pos_integer(),
            abs_path: Path.t()
          }

    defstruct [
      :filename,
      :function,
      :lineno,
      :colno,
      :abs_path
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
            frames: [Sentry.Payloads.Stacktrace.Frame.t()]
          }

    @enforce_keys [:frames]
    defstruct [:frames]
  end

  defmodule User do
    @moduledoc """
    The struct for the **user** interface.

    See <https://develop.sentry.dev/sdk/event-payloads/user>.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            id: term(),
            username: term(),
            email: String.t() | nil,
            ip_address: String.t() | nil,
            segment: term(),
            geo: Sentry.Payloads.User.Geo.t() | nil
          }

    defstruct [:id, :username, :email, :ip_address, :segment, :geo]
  end

  defmodule User.Geo do
    @moduledoc """
    The struct for the "geo" field of the **user** interface.

    See <https://develop.sentry.dev/sdk/event-payloads/user>.
    """

    @moduledoc since: "9.0.0"

    @typedoc since: "9.0.0"
    @type t() :: %__MODULE__{
            city: String.t() | nil,
            country_code: String.t() | nil,
            region: String.t() | nil
          }

    defstruct [:city, :country_code, :region]
  end

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
end
