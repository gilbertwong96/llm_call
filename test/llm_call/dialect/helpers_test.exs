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
end
