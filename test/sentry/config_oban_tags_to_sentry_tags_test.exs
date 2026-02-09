defmodule Sentry.ConfigObanTagsToSentryTagsTest do
  use ExUnit.Case, async: false

  import Sentry.TestHelpers

  describe "oban_tags_to_sentry_tags configuration validation" do
    defmodule TestTagsTransform do
      def transform(_job), do: %{"one_tag" => "one_tag_value"}
    end

    test "accepts nil" do
      assert :ok = put_test_config(integrations: [oban: [oban_tags_to_sentry_tags: nil]])
      assert Sentry.Config.integrations()[:oban][:oban_tags_to_sentry_tags] == nil
    end

    test "accepts function with arity 1" do
      fun = fn _job -> [] end
      assert :ok = put_test_config(integrations: [oban: [oban_tags_to_sentry_tags: fun]])
      assert Sentry.Config.integrations()[:oban][:oban_tags_to_sentry_tags] == fun
    end

    test "accepts MFA tuple with exported function" do
      assert :ok =
               put_test_config(
                 integrations: [oban: [oban_tags_to_sentry_tags: {TestTagsTransform, :transform}]]
               )

      assert Sentry.Config.integrations()[:oban][:oban_tags_to_sentry_tags] ==
               {TestTagsTransform, :transform}
    end

    test "rejects MFA tuple with non-exported function" do
      assert_raise ArgumentError, ~r/function.*is not exported/, fn ->
        put_test_config(
          integrations: [oban: [oban_tags_to_sentry_tags: {TestTagsTransform, :non_existent}]]
        )
      end
    end

    test "rejects function with wrong arity" do
      fun = fn -> ["one_tag"] end

      assert_raise ArgumentError, ~r/expected :oban_tags_to_sentry_tags to be/, fn ->
        put_test_config(integrations: [oban: [oban_tags_to_sentry_tags: fun]])
      end
    end

    test "rejects invalid types" do
      assert_raise ArgumentError, ~r/expected :oban_tags_to_sentry_tags to be/, fn ->
        put_test_config(integrations: [oban: [oban_tags_to_sentry_tags: "invalid"]])
      end

      assert_raise ArgumentError, ~r/expected :oban_tags_to_sentry_tags to be/, fn ->
        put_test_config(integrations: [oban: [oban_tags_to_sentry_tags: 123]])
      end

      assert_raise ArgumentError, ~r/expected :oban_tags_to_sentry_tags to be/, fn ->
        put_test_config(integrations: [oban: [oban_tags_to_sentry_tags: []]])
      end
    end
  end

  describe "should_report_error_callback configuration validation" do
    test "accepts nil" do
      assert :ok = put_test_config(integrations: [oban: [should_report_error_callback: nil]])
      assert Sentry.Config.integrations()[:oban][:should_report_error_callback] == nil
    end

    test "accepts function with arity 2" do
      fun = fn _worker, _job -> true end
      assert :ok = put_test_config(integrations: [oban: [should_report_error_callback: fun]])
      assert Sentry.Config.integrations()[:oban][:should_report_error_callback] == fun
    end

    test "rejects function with wrong arity" do
      fun = fn _job -> true end

      assert_raise ArgumentError, ~r/invalid value for :should_report_error_callback/, fn ->
        put_test_config(integrations: [oban: [should_report_error_callback: fun]])
      end
    end

    test "rejects invalid types" do
      assert_raise ArgumentError, ~r/invalid value for :should_report_error_callback/, fn ->
        put_test_config(integrations: [oban: [should_report_error_callback: "invalid"]])
      end

      assert_raise ArgumentError, ~r/invalid value for :should_report_error_callback/, fn ->
        put_test_config(integrations: [oban: [should_report_error_callback: 123]])
      end

      assert_raise ArgumentError, ~r/invalid value for :should_report_error_callback/, fn ->
        put_test_config(integrations: [oban: [should_report_error_callback: []]])
      end
    end
  end
end
