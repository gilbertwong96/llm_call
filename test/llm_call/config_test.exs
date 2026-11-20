defmodule LlmCall.ConfigTest do
  use ExUnit.Case, async: false

  alias LlmCall.{Config, MarkerJSON}

  test "new/1 prefers its options over the compile-time default" do
    assert Config.new().json == Elixir.JSON
    assert Config.new(json_library: MarkerJSON).json == MarkerJSON
  end

  test "capture_raw defaults to the value compiled into the struct" do
    assert %Config{}.capture_raw == :none
    assert Config.new().capture_raw == :none
    assert Config.new(capture_raw: :all).capture_raw == :all
  end

  test "capture_raw is compile-time, so a runtime setting does not move it" do
    Application.put_env(:llm_call, :capture_raw, :all)
    on_exit(fn -> Application.delete_env(:llm_call, :capture_raw) end)

    assert %Config{}.capture_raw == :none
    assert Config.new().capture_raw == :none
    assert Config.new(capture_raw: :response).capture_raw == :response
  end

  test "new/1 carries default_provider_options" do
    assert Config.new(default_provider_options: %{openai: %{"logprobs" => true}}).default_provider_options ==
             %{openai: %{"logprobs" => true}}
  end

  test "provider_options/2 deep-merges a nested default with the request" do
    config = Config.new(default_provider_options: %{openai: %{"extra_body" => %{"a" => 1}}})
    request = %LlmCall.Request{provider_options: %{openai: %{"extra_body" => %{"b" => 2}}}}

    assert Config.provider_options(request, config) ==
             %{openai: %{"extra_body" => %{"a" => 1, "b" => 2}}}
  end

  test "provider_options/2 still lets the request win on the same nested key" do
    config = Config.new(default_provider_options: %{openai: %{"extra_body" => %{"a" => 1}}})
    request = %LlmCall.Request{provider_options: %{openai: %{"extra_body" => %{"a" => 2}}}}

    assert Config.provider_options(request, config) == %{openai: %{"extra_body" => %{"a" => 2}}}
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
