defmodule LlmCall.StructsTest do
  use ExUnit.Case, async: true

  alias LlmCall.{
    Capabilities,
    Config,
    Content,
    EncodedRequest,
    Error,
    Message,
    Reasoning,
    ReasoningCapabilities,
    Request,
    Response,
    ToolCall,
    ToolResult,
    ToolSpec,
    Usage
  }

  test "defaults match the canonical IR contract" do
    assert %Request{
             model: nil,
             system: nil,
             messages: [],
             tools: [],
             tool_choice: :auto,
             output: :text,
             reasoning: nil,
             params: %{},
             provider_options: %{},
             stream: false
           } = %Request{}

    assert %Message{role: :user, content: []} = %Message{}
    assert %ToolSpec{kind: :function, provider_options: %{}, strict: nil} = %ToolSpec{}
    assert %ToolCall{name: nil, arguments_error: nil, index: nil} = %ToolCall{}
    assert %ToolResult{content: [], is_error: false} = %ToolResult{}
    assert %Response{content: [], stop_reason: :unknown, raw: nil} = %Response{}
    assert %Usage{input_tokens: nil, cache_write_tokens: nil} = %Usage{}
    assert %Error{retryable?: false, raw: nil} = %Error{}
    assert %Capabilities{structured_output: :none, streaming: false} = %Capabilities{}
    assert %ReasoningCapabilities{summary: [], efforts: []} = %ReasoningCapabilities{}
    assert %Reasoning{effort: nil, budget_tokens: nil, provider_options: %{}} = %Reasoning{}
    assert %Config{default_provider_options: %{}, capture_raw: :none} = %Config{}
    assert %EncodedRequest{method: :post, query: %{}, headers: [], body: %{}} = %EncodedRequest{}
  end

  test "content parts are distinguishable structs" do
    parts = [
      %Content.Text{text: "hi"},
      %Content.Image{source: {:base64, "AAA"}, media_type: "image/png"},
      %Content.File{source: {:url, "u"}, media_type: "application/pdf", filename: "a.pdf"},
      %Content.Thinking{text: "hmm", signature: "sig"},
      %Content.Raw{type: "audio", data: %{"id" => "a"}},
      %ToolCall{id: "call_1", name: "f"},
      %ToolResult{call_id: "call_1", content: "ok"}
    ]

    assert Enum.map(parts, & &1.__struct__) == [
             Content.Text,
             Content.Image,
             Content.File,
             Content.Thinking,
             Content.Raw,
             ToolCall,
             ToolResult
           ]
  end

  test "Response.text/1 joins text parts and ignores everything else" do
    response = %Response{
      content: [
        %Content.Text{text: "Hello"},
        %ToolCall{id: "call_1", name: "f"},
        %Content.Thinking{text: "hmm"},
        %Content.Text{text: " world"}
      ]
    }

    assert Response.text(response) == "Hello world"
    assert Response.text(%Response{}) == ""
  end

  test "Response.tool_calls/1 returns only ToolCall parts in order" do
    a = %ToolCall{id: "a", name: "f"}
    b = %ToolCall{id: "b", name: "g"}
    response = %Response{content: [%Content.Text{text: "x"}, a, %ToolResult{call_id: "z"}, b]}

    assert Response.tool_calls(response) == [a, b]
  end

  test "Config.provider_options/2 merges defaults first and request wins per namespace" do
    config = %Config{
      default_provider_options: %{
        openai: %{store: true, temperature_hint: 1},
        anthropic: %{beta: "x"}
      }
    }

    request = %Request{provider_options: %{openai: %{store: false}}}

    assert Config.provider_options(request, config) == %{
             openai: %{store: false, temperature_hint: 1},
             anthropic: %{beta: "x"}
           }
  end

  test "media-related defaults" do
    assert %Request{modalities: [:text]} = %Request{}
    assert %Capabilities{modalities: [:text]} = %Capabilities{}
    assert %LlmCall.Media.Capabilities{modalities: []} = %LlmCall.Media.Capabilities{}
    assert %EncodedRequest{method: :get} = %EncodedRequest{method: :get}

    video = %Content.Video{source: {:url, "https://example.com/a.mp4"}, media_type: "video/mp4"}
    assert video.media_type == "video/mp4"

    assert %Content.Video{source: {:base64, "AAA"}, media_type: nil} = %Content.Video{
             source: {:base64, "AAA"}
           }
  end

  test "Config.deep_merge/2 merges nested maps and replaces other values" do
    assert Config.deep_merge(%{"a" => %{"b" => 1, "c" => 2}}, %{"a" => %{"c" => 3}}) ==
             %{"a" => %{"b" => 1, "c" => 3}}

    assert Config.deep_merge(%{"a" => [1]}, %{"a" => [2]}) == %{"a" => [2]}
    assert Config.deep_merge(%{"a" => 1}, %{"a" => %{"b" => 2}}) == %{"a" => %{"b" => 2}}
    assert Config.deep_merge(%{}, %{"a" => 1}) == %{"a" => 1}
  end

  test "JSON.encode/1 and decode/1 return tagged results" do
    assert LlmCall.JSON.encode(%{"city" => "Oslo"}) == {:ok, ~s({"city":"Oslo"})}
    assert LlmCall.JSON.encode(%{}) == {:ok, "{}"}
    assert {:error, _reason} = LlmCall.JSON.encode(%{"at" => {1, 2}})

    assert LlmCall.JSON.decode(~s({"a":1})) == {:ok, %{"a" => 1}}
    assert {:error, _reason} = LlmCall.JSON.decode("{")
    assert {:error, {:not_a_binary, :not_a_string}} = LlmCall.JSON.decode(:not_a_string)
  end

  test "JSON facade accepts tagged and bang modules" do
    assert {:ok, ~s({"a":1})} = LlmCall.JSON.encode(Elixir.JSON, %{a: 1})
    assert {:ok, %{"a" => 1}} = LlmCall.JSON.decode(Elixir.JSON, ~s({"a":1}))

    assert {:ok, "MARKER:" <> _} = LlmCall.JSON.encode(LlmCall.MarkerJSON, %{a: 1})
    assert {:ok, %{"a" => 1}} = LlmCall.JSON.decode(LlmCall.MarkerJSON, ~s({"a":1}))
  end
end
