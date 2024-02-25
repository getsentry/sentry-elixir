defmodule Sentry.CheckInTest do
  use Sentry.Case, async: false

  alias Sentry.CheckIn

  doctest CheckIn

  describe "new/1" do
    test "works with all default options" do
      assert %CheckIn{
               check_in_id: check_in_id,
               monitor_slug: "my-slug",
               status: :ok,
               environment: "test"
             } = CheckIn.new(status: :ok, monitor_slug: "my-slug")

      assert is_binary(check_in_id) and byte_size(check_in_id) > 0
    end

    test "works with an explicit ID" do
      check_in_id = "my-id"

      assert %CheckIn{
               check_in_id: ^check_in_id,
               monitor_slug: "my-slug",
               status: :ok,
               environment: "test"
             } = CheckIn.new(status: :ok, monitor_slug: "my-slug", check_in_id: check_in_id)
    end

    test "works with arbitrary context" do
      assert %CheckIn{
               monitor_slug: "my-slug",
               status: :ok,
               contexts: %{trace_id: "1234"}
             } =
               CheckIn.new(
                 status: :ok,
                 monitor_slug: "my-slug",
                 contexts: %{trace_id: "1234"}
               )
    end

    test "works with a crontab monitor config" do
      assert %CheckIn{
               check_in_id: check_in_id,
               monitor_slug: "my-slug",
               status: :ok,
               environment: "test",
               monitor_config: %{
                 schedule: %{
                   type: :crontab,
                   value: "0 * * * *"
                 }
               }
             } =
               CheckIn.new(
                 status: :ok,
                 monitor_slug: "my-slug",
                 monitor_config: [schedule: [type: :crontab, value: "0 * * * *"]]
               )

      assert is_binary(check_in_id) and byte_size(check_in_id) > 0
    end

    test "works with a interval monitor config" do
      assert %CheckIn{
               check_in_id: check_in_id,
               monitor_slug: "my-slug",
               status: :ok,
               environment: "test",
               monitor_config: %{
                 schedule: %{
                   type: :interval,
                   value: 3,
                   unit: :hour
                 }
               }
             } =
               CheckIn.new(
                 status: :ok,
                 monitor_slug: "my-slug",
                 monitor_config: [schedule: [type: :interval, value: 3, unit: :hour]]
               )

      assert is_binary(check_in_id) and byte_size(check_in_id) > 0

      assert_raise NimbleOptions.ValidationError, ~r"required :unit option not found", fn ->
        CheckIn.new(
          status: :ok,
          monitor_slug: "my-slug",
          monitor_config: [schedule: [type: :interval, value: 3]]
        )
      end
    end
  end
end
