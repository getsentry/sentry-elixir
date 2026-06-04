defmodule PhoenixApp.Billing.CreditCard do
  @moduledoc """
  A plain value struct for an in-flight card payment.

  It is deliberately a plain struct, not an `Ecto.Schema`, and uses no `redact:`
  option — which is typical for ad-hoc value objects that are never persisted
  (storing a raw PAN would be a PCI violation). As a result its default `Inspect`
  implementation renders every field, including the card number.
  """

  @type t :: %__MODULE__{
          cardholder: String.t() | nil,
          number: String.t() | nil,
          cvv: String.t() | nil
        }

  defstruct [:cardholder, :number, :cvv]
end
