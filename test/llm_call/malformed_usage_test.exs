defmodule LlmCall.MalformedUsageTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Content, Error, Message, Request, Usage}

  defp chat_payload(usage) do
    %{"choices" => [%{"message" => %{"content" => "x"}}], "usage" => usage}
  end

  defp responses_payload(usage), do: %{"output" => [], "usage" => usage}

  defp anthropic_payload(usage) do
    %{"content" => [%{"type" => "text", "text" => "x"}], "usage" => usage}
  end

  test "Chat ignores non-map token detail objects" do
    for details <- ["10", [], 1, 1.5, true] do
      assert {:ok, %{usage: %Usage{} = usage}} =
               LlmCall.Dialect.OpenAI.Chat.decode_response(
                 chat_payload(%{"prompt_tokens" => 1, "prompt_tokens_details" => details}),
                 %Config{}
               )

      assert usage.input_tokens == 1
      assert usage.cache_read_tokens == nil
    end
  end

  test "Responses ignores non-map token detail objects" do
    for details <- ["10", [], 1, 1.5, true] do
      assert {:ok, %{usage: %Usage{} = usage}} =
               LlmCall.Dialect.OpenAI.Responses.decode_response(
                 responses_payload(%{"input_tokens" => 1, "input_tokens_details" => details}),
                 %Config{}
               )

      assert usage.input_tokens == 1
      assert usage.cache_read_tokens == nil
    end
  end

  test "Anthropic does not do arithmetic on non-integer tokens" do
    for usage <- [
          %{"input_tokens" => "10", "output_tokens" => 5},
          %{"input_tokens" => 10, "output_tokens" => "5"},
          %{"input_tokens" => 1.5, "output_tokens" => 2},
          %{"input_tokens" => -1, "output_tokens" => 2}
        ] do
      assert {:ok, %{usage: %Usage{} = usage}} =
               LlmCall.Dialect.Anthropic.Messages.decode_response(
                 anthropic_payload(usage),
                 %Config{}
               )

      for field <- [:input_tokens, :output_tokens, :total_tokens] do
        value = Map.fetch!(usage, field)

        assert is_nil(value) or (is_integer(value) and value >= 0),
               "#{field} must be a non-negative integer or nil, got: #{inspect(value)}"
      end
    end
  end

  test "a streamed usage chunk with a non-map detail object does not raise" do
    codec = LlmCall.Dialect.OpenAI.Chat

    request = %Request{
      model: "gpt-4o",
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }

    assert {:ok, state} = codec.init_stream(request, %Config{})

    assert {:ok, _events, _state} =
             codec.decode_stream_event(
               %{"choices" => [], "usage" => %{"prompt_tokens_details" => "x"}},
               %Config{},
               state
             )
  end

  test "a malformed error payload still decodes to a canonical error" do
    assert %Error{kind: :invalid_response} =
             LlmCall.Dialect.OpenAI.Chat.decode_error(%{"error" => "x"}, %Config{})
  end
end
