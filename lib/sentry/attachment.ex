defmodule Sentry.Attachment do
  @moduledoc """
  A struct to represent an **attachment**.

  You can send attachments over to Sentry alongside an event. See:
  <https://develop.sentry.dev/sdk/envelopes/#attachment>.

  To add attachments, use `Sentry.Context.add_attachment/1`.

  *Available since v10.1.0*.
  """

  @moduledoc since: "10.1.0"

  @typedoc """
  The type for the attachment struct.
  """
  @typedoc since: "10.1.0"
  @type t() :: %__MODULE__{
          filename: String.t(),
          data: binary(),
          attachment_type: String.t() | nil,
          content_type: String.t() | nil
        }

  @enforce_keys [:filename, :data]
  defstruct [:filename, :attachment_type, :content_type, :data]
end
