defmodule LlmCall.ConfigTest do
  use ExUnit.Case, async: false

  alias LlmCall.{Config, JSON, MarkerJSON}

  test "new/1 prefers its option, then the application environment, then the default" do
    on_exit(fn -> Application.delete_env(:llm_call, :json) end)
    Application.delete_env(:llm_call, :json)

    assert Config.new().json == JSON

    Application.put_env(:llm_call, :json, MarkerJSON)
    assert Config.new().json == MarkerJSON
    assert Config.new(json: JSON).json == JSON
  end

  test "new/1 carries default_provider_options" do
    assert Config.new(default_provider_options: %{openai: %{"logprobs" => true}}).default_provider_options ==
             %{openai: %{"logprobs" => true}}
  end

  test "an explicit %Config{} opts out of the application default" do
    on_exit(fn -> Application.delete_env(:llm_call, :json) end)
    Application.put_env(:llm_call, :json, MarkerJSON)

    assert %Config{}.json == JSON
  end
end
