defmodule Sentry.UUID do
  @moduledoc false

  @rfc_4122_variant10 2
  @uuid_v4_identifier 4

  @type t() :: <<_::256>>

  # Per http://www.ietf.org/rfc/rfc4122.txt
  @spec uuid4_hex() :: t()
  def uuid4_hex do
    <<time_low_mid::48, _version::4, time_high::12, _reserved::2, rest::62>> =
      :crypto.strong_rand_bytes(16)

    <<time_low_mid::48, @uuid_v4_identifier::4, time_high::12, @rfc_4122_variant10::2, rest::62>>
    |> Base.encode16(case: :lower)
  end
end
