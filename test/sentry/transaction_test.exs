defmodule Sentry.TransactionTest do
  use Sentry.Case, async: true

  alias Sentry.Transaction

  import Sentry.TestHelpers

  describe "to_payload/1" do
    setup do
      {:ok, %{transaction: create_transaction()}}
    end

    test "returns a map representation of the transaction", %{transaction: transaction} do
      transaction_payload = Transaction.to_payload(transaction)

      [child_span] = transaction_payload[:spans]

      assert transaction_payload[:contexts][:trace][:trace_id] == "trace-312"

      assert child_span[:parent_span_id] == transaction.span_id
      assert child_span[:span_id] == "span-123"
    end
  end
end
