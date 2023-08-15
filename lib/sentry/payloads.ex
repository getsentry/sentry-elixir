defmodule Sentry.Payloads do
  @moduledoc false

  defmodule Event do
    @moduledoc false
    # https://develop.sentry.dev/sdk/event-payloads/

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
            environment: String.t(),
            modules: %{optional(String.t()) => String.t()},
            extra: map(),
            fingerprint: [String.t()],

            # Possible payloads.
            exception: [Sentry.Payloads.Exception.t(), ...] | nil
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
      :exception,

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

  defmodule Exception do
    @moduledoc false
    # https://develop.sentry.dev/sdk/event-payloads/exception/

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
    @moduledoc false
    # https://develop.sentry.dev/sdk/event-payloads/stacktrace/

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
    @moduledoc false
    # https://develop.sentry.dev/sdk/event-payloads/stacktrace/

    @type t() :: %__MODULE__{
            frames: [Sentry.Payloads.Stacktrace.Frame.t()]
          }

    @enforce_keys [:frames]
    defstruct [:frames]
  end
end
