defmodule PhoenixApp.Billing do
  @moduledoc """
  A small payments context, standing in for the kind of billing code a real app
  has. `charge/3` is guarded by the set of currencies the processor supports.
  """

  alias PhoenixApp.Billing.CreditCard

  @supported_currencies ~w(USD EUR GBP)

  @doc """
  Charges a card for `amount` (in minor units) in a supported currency.

  An unsupported currency matches no clause and raises `FunctionClauseError`. The
  `%CreditCard{}` passed in then rides along in that frame's stacktrace args.
  """
  @spec charge(CreditCard.t(), pos_integer(), String.t()) :: {:ok, map()}
  def charge(%CreditCard{} = card, amount, currency)
      when currency in @supported_currencies do
    {:ok, %{card: card, amount: amount, currency: currency}}
  end
end
