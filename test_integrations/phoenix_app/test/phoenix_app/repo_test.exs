defmodule PhoenixApp.RepoTest do
  use PhoenixApp.DataCase

  alias PhoenixApp.{Repo, Accounts.User}

  import Sentry.TestHelpers

  setup do
    put_test_config(dsn: "http://public:secret@localhost:8080/1")

    Sentry.Test.start_collecting_sentry_reports()
  end

  test "instrumented top-level ecto transaction span" do
    Repo.all(User) |> Enum.map(& &1.id)

    transactions = Sentry.Test.pop_sentry_transactions()

    assert length(transactions) == 1

    assert [transaction] = transactions

    assert transaction.transaction_info == %{source: "component"}
    assert transaction.contexts.trace.op == "db.sql.ecto"
    assert String.starts_with?(transaction.contexts.trace.description, "SELECT")
    assert transaction.contexts.trace.data["db.system"] == :sqlite
  end
end
