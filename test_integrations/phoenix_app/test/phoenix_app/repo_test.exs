defmodule PhoenixApp.RepoTest do
  use PhoenixApp.DataCase, async: false

  alias PhoenixApp.{Repo, Accounts.User}

  import Sentry.TestHelpers

  setup do
    setup_bypass(traces_sample_rate: 1.0)
  end

  test "instrumented top-level ecto transaction span", %{bypass: bypass} do
    ref = setup_bypass_envelope_collector(bypass)

    Repo.all(User) |> Enum.map(& &1.id)

    assert [tx] = collect_envelopes(ref, 1) |> extract_transactions()

    assert tx["transaction_info"] == %{"source" => "custom"}

    assert tx["contexts"]["trace"]["op"] == "db"

    assert tx["contexts"]["trace"]["data"]["db.system"] == "sqlite"
    assert tx["contexts"]["trace"]["data"]["db.type"] == "sql"
    assert tx["contexts"]["trace"]["data"]["db.instance"] == "db/test.sqlite3"
    assert tx["contexts"]["trace"]["data"]["db.name"] == "db/test.sqlite3"

    assert String.starts_with?(tx["contexts"]["trace"]["description"], "SELECT")
    assert String.starts_with?(tx["contexts"]["trace"]["data"]["db.statement"], "SELECT")

    refute Map.has_key?(tx["contexts"]["trace"]["data"], "db.url")
  end
end
