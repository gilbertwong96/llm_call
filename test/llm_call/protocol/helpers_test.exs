defmodule LlmCall.Protocol.HelpersTest do
  use ExUnit.Case, async: true

  alias LlmCall.Protocol.Helpers

  test "retryable?/2 is the single rule for the retry hint" do
    assert Helpers.retryable?("rate_limit_exceeded", ["rate_limit_exceeded"])
    refute Helpers.retryable?(nil, ["rate_limit_exceeded"])
    refute Helpers.retryable?("other", ["rate_limit_exceeded"])
  end
end
