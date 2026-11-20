defmodule LlmCall.ConfigTest do
  use ExUnit.Case, async: false

  alias LlmCall.{Config, MarkerJSON}

  test "new/1 prefers its options over the compile-time default" do
    assert Config.new().json == Elixir.JSON
    assert Config.new(json_library: MarkerJSON).json == MarkerJSON
  end

  test "new/1 carries default_provider_options" do
    assert Config.new(default_provider_options: %{openai: %{"logprobs" => true}}).default_provider_options ==
             %{openai: %{"logprobs" => true}}
  end

  test "new/1 rejects the removed json: option" do
    assert_raise ArgumentError, ~r/unknown option :json/, fn ->
      Config.new(json: MarkerJSON)
    end
  end

  test "new/1 validates capture_raw and json_library" do
    assert_raise ArgumentError, ~r/:capture_raw/, fn ->
      Config.new(capture_raw: :everything)
    end

    assert_raise ArgumentError, ~r/:json_library/, fn ->
      Config.new(json_library: "JSON")
    end

    assert_raise ArgumentError, ~r/:json_library/, fn ->
      Config.new(json_library: nil)
    end
  end

  test "an explicit %Config{} uses the compiled default" do
    assert %Config{}.json == Elixir.JSON
  end
end
