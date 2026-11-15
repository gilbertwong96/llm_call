defmodule LlmDialect.Fixtures.AnthropicMessages do
  @moduledoc """
  Anthropic Messages payloads shaped like the provider's responses, for adapter tests.
  """

  def text_response do
    %{
      "id" => "msg_123",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-5",
      "content" => [%{"type" => "text", "text" => "Hello"}],
      "stop_reason" => "end_turn",
      "stop_sequence" => nil,
      "usage" => %{
        "input_tokens" => 12,
        "output_tokens" => 5,
        "cache_read_input_tokens" => 3,
        "cache_creation_input_tokens" => 7
      }
    }
  end

  def tool_response do
    %{
      "id" => "msg_456",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-5",
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "get_weather",
          "input" => %{"city" => "Oslo"}
        }
      ],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 8, "output_tokens" => 4}
    }
  end

  def mixed_response do
    %{
      "id" => "msg_789",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-5",
      "content" => [
        %{"type" => "thinking", "thinking" => "step", "signature" => "sig"},
        %{"type" => "text", "text" => "Hi"},
        %{"type" => "redacted_thinking", "data" => "xxx"}
      ],
      "stop_reason" => "end_turn"
    }
  end

  def response_with_stop(stop_reason) do
    put_in(text_response(), ["stop_reason"], stop_reason)
  end

  def error_payload do
    %{"type" => "error", "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}}
  end

  def message_start do
    %{
      "type" => "message_start",
      "message" => %{
        "id" => "msg_1",
        "model" => "claude-sonnet-4-5",
        "usage" => %{"input_tokens" => 12, "output_tokens" => 1}
      }
    }
  end

  def text_stream do
    [
      message_start(),
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Hel"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "lo"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 5}
      },
      %{"type" => "message_stop"}
    ]
  end

  def tool_stream do
    [
      message_start(),
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "get_weather",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"city":)}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("Oslo"})}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 3}
      },
      %{"type" => "message_stop"}
    ]
  end

  def thinking_stream do
    [
      message_start(),
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "think"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_stop"}
    ]
  end
end
