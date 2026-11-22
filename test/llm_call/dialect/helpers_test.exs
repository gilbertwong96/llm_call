defmodule LlmCall.Dialect.HelpersTest do
  use ExUnit.Case, async: true

  alias LlmCall.Dialect.Helpers

  test "capture_response/2 keeps a map and ignores any other term" do
    config = %LlmCall.Config{capture_raw: :all}

    assert Helpers.capture_response(config, %{"a" => 1}) == %{"a" => 1}
    assert Helpers.capture_response(config, [1, 2]) == nil
    assert Helpers.capture_response(%LlmCall.Config{}, %{"a" => 1}) == nil
  end

  test "retryable?/2 is the single rule for the retry hint" do
    assert Helpers.retryable?("rate_limit_exceeded", ["rate_limit_exceeded"])
    refute Helpers.retryable?(nil, ["rate_limit_exceeded"])
    refute Helpers.retryable?("other", ["rate_limit_exceeded"])
    refute Helpers.retryable?(429, ["429"])
    refute Helpers.retryable?(%{"code" => 429}, ["429"])
  end

  test "code/1 normalizes provider codes so Error.code is always a string" do
    assert Helpers.code("RESOURCE_EXHAUSTED") == "RESOURCE_EXHAUSTED"
    assert Helpers.code(429) == "429"
    assert Helpers.code(nil) == nil
    assert Helpers.code(%{"weird" => true}) == nil
  end

  describe "validate_param_values/4" do
    @spec_map %{
      temperature: {:number, 0, 2},
      max_tokens: {:integer, 1, :infinity},
      seed: :integer,
      stop: {:stop, 4}
    }
    @keys [:temperature, :max_tokens, :seed, :stop]

    defp validate_params(params, codec \\ :test_codec) do
      Helpers.validate_param_values(params, @keys, @spec_map, codec)
    end

    test "accepts values inside the declared range" do
      assert :ok == validate_params(%{temperature: 0})
      assert :ok == validate_params(%{temperature: 2})
      assert :ok == validate_params(%{temperature: 0.7})
      assert :ok == validate_params(%{max_tokens: 1})
      assert :ok == validate_params(%{seed: -1})
      assert :ok == validate_params(%{stop: "END"})
      assert :ok == validate_params(%{stop: ["a", "b"]})
    end

    test "ignores a nil value, which means provider default" do
      assert :ok == validate_params(%{temperature: nil, max_tokens: nil})
      assert :ok == validate_params(%{})
    end

    test "rejects a value outside its range or of the wrong type" do
      assert {:error, %{kind: :validation, message: message}} =
               validate_params(%{temperature: 2.1})

      assert message =~ "between 0 and 2"

      assert {:error, %{message: message}} = validate_params(%{temperature: "hot"})
      assert message =~ "must be a number"

      assert {:error, %{message: message}} = validate_params(%{max_tokens: 0})
      assert message =~ "at least 1"

      assert {:error, %{message: message}} = validate_params(%{seed: "x"})
      assert message =~ "must be an integer"
    end

    test "rejects a stop that is empty, blank, over the limit, or not a string list" do
      for stop <- ["", [], [""], ["a", "b", "c", "d", "e"], 123] do
        assert {:error, %{kind: :validation, message: message}} = validate_params(%{stop: stop})
        assert message =~ "stop"
      end
    end

    test "an unknown key is still rejected before its value is considered" do
      assert {:error, %{message: message}} = validate_params(%{unknown: 1})
      assert message =~ "not supported"
    end
  end
end
