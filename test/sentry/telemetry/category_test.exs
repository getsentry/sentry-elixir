defmodule Sentry.Telemetry.CategoryTest do
  use ExUnit.Case, async: true

  alias Sentry.Telemetry.Category

  describe "priority/1" do
    test "returns :critical for :error category" do
      assert Category.priority(:error) == :critical
    end

    test "returns :high for :check_in category" do
      assert Category.priority(:check_in) == :high
    end

    test "returns :medium for :transaction category" do
      assert Category.priority(:transaction) == :medium
    end

    test "returns :low for :log category" do
      assert Category.priority(:log) == :low
    end
  end

  describe "weight/1" do
    test "returns 5 for :critical priority" do
      assert Category.weight(:critical) == 5
    end

    test "returns 4 for :high priority" do
      assert Category.weight(:high) == 4
    end

    test "returns 3 for :medium priority" do
      assert Category.weight(:medium) == 3
    end

    test "returns 2 for :low priority" do
      assert Category.weight(:low) == 2
    end
  end

  describe "default_config/1" do
    test "returns correct defaults for :error category" do
      config = Category.default_config(:error)
      assert config.capacity == 100
      assert config.batch_size == 1
      assert config.timeout == nil
    end

    test "returns correct defaults for :check_in category" do
      config = Category.default_config(:check_in)
      assert config.capacity == 100
      assert config.batch_size == 1
      assert config.timeout == nil
    end

    test "returns correct defaults for :transaction category" do
      config = Category.default_config(:transaction)
      assert config.capacity == 1000
      assert config.batch_size == 1
      assert config.timeout == nil
    end

    test "returns correct defaults for :log category" do
      config = Category.default_config(:log)
      assert config.capacity == 1000
      assert config.batch_size == 100
      assert config.timeout == 5000
    end
  end

  describe "all/0" do
    test "returns all categories" do
      categories = Category.all()
      assert :error in categories
      assert :check_in in categories
      assert :transaction in categories
      assert :log in categories
      assert length(categories) == 4
    end
  end

  describe "priorities/0" do
    test "returns all priorities in descending order" do
      assert Category.priorities() == [:critical, :high, :medium, :low]
    end
  end
end
