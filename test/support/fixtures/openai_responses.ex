defmodule LlmCall.Fixtures.OpenAIResponses do
  @moduledoc """
  OpenAI Responses payloads shaped like the provider's responses and events.
  """

  def text_response do
    %{
      "id" => "resp_1",
      "object" => "response",
      "model" => "gpt-4.1",
      "status" => "completed",
      "output" => [
        message_item("msg_1", [
          %{"type" => "output_text", "text" => "Hello there", "annotations" => []}
        ])
      ],
      "usage" => usage()
    }
  end

  def annotated_response do
    %{
      text_response()
      | "output" => [
          message_item("msg_1", [
            %{
              "type" => "output_text",
              "text" => "See the file",
              "annotations" => [
                %{"type" => "file_citation", "file_id" => "file_1", "filename" => "a.md"}
              ]
            }
          ])
        ]
    }
  end

  def tool_call_response do
    %{
      "id" => "resp_2",
      "model" => "gpt-4.1",
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_1",
          "name" => "get_weather",
          "arguments" => ~s({"city":"Oslo"}),
          "status" => "completed"
        }
      ],
      "usage" => usage()
    }
  end

  def malformed_tool_call_response do
    put_in(tool_call_response(), ["output", Access.at(0), "arguments"], ~s({"city":))
  end

  def reasoning_response do
    %{
      "id" => "resp_3",
      "model" => "o4-mini",
      "status" => "completed",
      "output" => [
        %{
          "type" => "reasoning",
          "id" => "rs_1",
          "summary" => [%{"type" => "summary_text", "text" => "Checked the weather"}],
          "encrypted_content" => "enc_1"
        },
        message_item("msg_2", [
          %{"type" => "output_text", "text" => "It is sunny", "annotations" => []}
        ])
      ],
      "usage" => usage()
    }
  end

  def builtin_tool_response do
    %{
      "id" => "resp_4",
      "model" => "gpt-4.1",
      "status" => "completed",
      "output" => [
        %{"type" => "web_search_call", "id" => "ws_1", "status" => "completed"}
      ],
      "usage" => usage()
    }
  end

  def incomplete_response do
    %{
      "id" => "resp_5",
      "model" => "gpt-4.1",
      "status" => "incomplete",
      "incomplete_details" => %{"reason" => "max_output_tokens"},
      "output" => [
        message_item("msg_3", [
          %{"type" => "output_text", "text" => "Partial", "annotations" => []}
        ])
      ],
      "usage" => usage()
    }
  end

  def failed_response do
    %{
      "id" => "resp_6",
      "model" => "gpt-4.1",
      "status" => "failed",
      "error" => %{"code" => "server_error", "message" => "boom"},
      "output" => []
    }
  end

  def error_payload do
    %{
      "error" => %{
        "message" => "bad request",
        "type" => "invalid_request_error",
        "code" => "invalid"
      }
    }
  end

  def created(response \\ text_response()) do
    %{
      "type" => "response.created",
      "response" => Map.put(response, "status", "in_progress")
    }
  end

  def in_progress(response \\ text_response()) do
    %{"type" => "response.in_progress", "response" => Map.put(response, "status", "in_progress")}
  end

  def output_item_added(item, index) do
    %{"type" => "response.output_item.added", "output_index" => index, "item" => item}
  end

  def output_item_done(item, index) do
    %{"type" => "response.output_item.done", "output_index" => index, "item" => item}
  end

  def content_part_added(part, index) do
    %{
      "type" => "response.content_part.added",
      "output_index" => index,
      "content_index" => 0,
      "part" => part
    }
  end

  def content_part_done(part, index) do
    %{
      "type" => "response.content_part.done",
      "output_index" => index,
      "content_index" => 0,
      "part" => part
    }
  end

  def text_delta(delta, index \\ 0) do
    %{
      "type" => "response.output_text.delta",
      "output_index" => index,
      "content_index" => 0,
      "delta" => delta
    }
  end

  def text_done(text, index \\ 0) do
    %{
      "type" => "response.output_text.done",
      "output_index" => index,
      "content_index" => 0,
      "text" => text
    }
  end

  def arguments_delta(delta, index \\ 0) do
    %{
      "type" => "response.function_call_arguments.delta",
      "output_index" => index,
      "delta" => delta
    }
  end

  def arguments_done(arguments, index \\ 0) do
    %{
      "type" => "response.function_call_arguments.done",
      "output_index" => index,
      "call_id" => "call_1",
      "name" => "get_weather",
      "arguments" => arguments
    }
  end

  def reasoning_delta(delta, index \\ 0) do
    %{
      "type" => "response.reasoning_summary_text.delta",
      "output_index" => index,
      "delta" => delta
    }
  end

  def completed(response \\ text_response()) do
    %{"type" => "response.completed", "response" => response}
  end

  def incomplete_event do
    %{"type" => "response.incomplete", "response" => incomplete_response()}
  end

  def failed_event do
    %{"type" => "response.failed", "response" => failed_response()}
  end

  def error_event do
    %{"type" => "error", "code" => "server_error", "message" => "boom"}
  end

  def message_item(id, content) do
    %{
      "type" => "message",
      "id" => id,
      "role" => "assistant",
      "status" => "completed",
      "content" => content
    }
  end

  def usage do
    %{
      "input_tokens" => 12,
      "output_tokens" => 5,
      "total_tokens" => 17,
      "input_tokens_details" => %{"cached_tokens" => 3},
      "output_tokens_details" => %{"reasoning_tokens" => 0}
    }
  end
end
