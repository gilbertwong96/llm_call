defmodule LlmCall.ConfigTest do
  use ExUnit.Case, async: false

  alias LlmCall.{Config, MarkerJSON}

  test "new/1 prefers its options over the compile-time default" do
    assert Config.new().json == Elixir.JSON
    assert Config.new(json: MarkerJSON).json == MarkerJSON
    assert Config.new(json_library: MarkerJSON).json == MarkerJSON
  end

  test "new/1 carries default_provider_options" do
    assert Config.new(default_provider_options: %{openai: %{"logprobs" => true}}).default_provider_options ==
             %{openai: %{"logprobs" => true}}
  end

  test "an explicit %Config{} uses the compiled default" do
    assert %Config{}.json == Elixir.JSON
  end
end
