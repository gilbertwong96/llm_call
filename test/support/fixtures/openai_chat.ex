defmodule LlmCall.Fixtures.OpenAIChat do
  @moduledoc """
  OpenAI Chat payloads shaped like the provider's responses and stream chunks.
  """

  def text_response do
    %{
      "id" => "chatcmpl-1",
      "object" => "chat.completion",
      "model" => "gpt-4o",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => "Hello there"},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 12,
        "completion_tokens" => 5,
        "total_tokens" => 17,
        "prompt_tokens_details" => %{"cached_tokens" => 3, "cache_write_tokens" => 2},
        "completion_tokens_details" => %{"reasoning_tokens" => 0}
      }
    }
  end

  def tool_call_response do
    %{
      "id" => "chatcmpl-2",
      "model" => "gpt-4o",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Oslo"})}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }
  end

  def malformed_tool_call_response do
    put_in(
      tool_call_response(),
      ["choices", Access.at(0), "message", "tool_calls", Access.at(0), "function", "arguments"],
      ~s({"city":)
    )
  end

  def array_tool_call_response do
    put_in(
      tool_call_response(),
      ["choices", Access.at(0), "message", "tool_calls", Access.at(0), "function", "arguments"],
      "[1,2]"
    )
  end

  def reasoning_and_refusal_response do
    %{
      "id" => "chatcmpl-3",
      "model" => "gpt-4o",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "reasoning_content" => "step 1",
            "content" => "Answer",
            "refusal" => "I cannot"
          },
          "finish_reason" => "stop"
        }
      ]
    }
  end

  def two_choices_response do
    %{
      "id" => "chatcmpl-4",
      "model" => "gpt-4o",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => "first"},
          "finish_reason" => "stop"
        },
        %{
          "index" => 1,
          "message" => %{"role" => "assistant", "content" => "second"},
          "finish_reason" => "stop"
        }
      ]
    }
  end

  def unknown_finish_response do
    %{
      "id" => "chatcmpl-5",
      "model" => "gpt-4o",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => "x"},
          "finish_reason" => "weird"
        }
      ]
    }
  end

  def error_payload do
    %{
      "error" => %{
        "message" => "Rate limit reached",
        "type" => "rate_limit_error",
        "code" => "rate_limit_exceeded"
      }
    }
  end

  def text_chunk(text) do
    %{
      "id" => "chatcmpl-6",
      "model" => "gpt-4o",
      "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]
    }
  end

  def text_chunks do
    [
      text_chunk("Hel"),
      text_chunk("lo"),
      %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]},
      %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 5, "total_tokens" => 17}
      }
    ]
  end

  def tool_call_chunks do
    [
      text_chunk("Looking"),
      %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "get_weather", "arguments" => ~s({"city":)}
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      },
      %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => ~s("Oslo"})}}]
            },
            "finish_reason" => nil
          }
        ]
      },
      %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]}
    ]
  end

  def usage_split_chunks do
    [
      %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 20, "total_tokens" => 20}
      },
      %{"choices" => [], "usage" => %{"completion_tokens" => 4}}
    ]
  end
end
