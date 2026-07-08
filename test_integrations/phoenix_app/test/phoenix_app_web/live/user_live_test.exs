defmodule PhoenixAppWeb.UserLiveTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.Test.Assertions
  import Phoenix.LiveViewTest
  import PhoenixApp.AccountsFixtures

  @create_attrs %{name: "some name", age: 42}
  @update_attrs %{name: "some updated name", age: 43}
  @invalid_attrs %{name: nil, age: nil}

  setup do
    Sentry.Test.setup_sentry(collect_envelopes: true, traces_sample_rate: 1.0)
  end

  defp create_user(_) do
    user = user_fixture()
    %{user: user}
  end

  describe "Index" do
    setup [:create_user]

    test "lists all users", %{conn: conn, user: user} do
      {:ok, _index_live, html} = live(conn, ~p"/users")

      assert html =~ "Listing Users"
      assert html =~ user.name
    end

    test "saves new user", %{conn: conn, ref: ref} do
      {:ok, index_live, _html} = live(conn, ~p"/users")

      assert index_live |> element("a", "New User") |> render_click() =~
               "New User"

      assert_patch(index_live, ~p"/users/new")

      assert index_live
             |> form("#user-form", user: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#user-form", user: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/users")

      html = render(index_live)
      assert html =~ "User created successfully"
      assert html =~ "some name"

      transaction_save =
        find_sentry_transaction!(ref,
          count: 10,
          timeout: 2000,
          transaction: "PhoenixAppWeb.UserLive.Index.handle_event#save",
          transaction_info: %{"source" => "custom"},
          contexts: %{
            trace: %{
              op: "PhoenixAppWeb.UserLive.Index.handle_event#save",
              origin: "opentelemetry_phoenix"
            }
          }
        )

      assert length(transaction_save["spans"]) == 1
      assert [span] = transaction_save["spans"]
      assert span["op"] == "db"
      assert span["description"] =~ "INSERT INTO \"users\""
      assert span["data"]["db.system"] == "sqlite"
      assert span["data"]["db.type"] == "sql"
      assert span["origin"] == "opentelemetry_ecto"
    end

    test "updates user in listing", %{conn: conn, user: user} do
      {:ok, index_live, _html} = live(conn, ~p"/users")

      assert index_live |> element("#users-#{user.id} a", "Edit") |> render_click() =~
               "Edit User"

      assert_patch(index_live, ~p"/users/#{user}/edit")

      assert index_live
             |> form("#user-form", user: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#user-form", user: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/users")

      html = render(index_live)
      assert html =~ "User updated successfully"
      assert html =~ "some updated name"
    end

    test "deletes user in listing", %{conn: conn, user: user} do
      {:ok, index_live, _html} = live(conn, ~p"/users")

      assert index_live |> element("#users-#{user.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#users-#{user.id}")
    end
  end

  describe "Show" do
    setup [:create_user]

    test "displays user", %{conn: conn, user: user} do
      {:ok, _show_live, html} = live(conn, ~p"/users/#{user}")

      assert html =~ "Show User"
      assert html =~ user.name
    end

    test "updates user within modal", %{conn: conn, user: user} do
      {:ok, show_live, _html} = live(conn, ~p"/users/#{user}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit User"

      assert_patch(show_live, ~p"/users/#{user}/show/edit")

      assert show_live
             |> form("#user-form", user: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#user-form", user: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/users/#{user}")

      html = render(show_live)
      assert html =~ "User updated successfully"
      assert html =~ "some updated name"
    end
  end
end
