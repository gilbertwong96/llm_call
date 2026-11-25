defmodule LlmCall.Fixtures.BedrockConverse do
  @moduledoc "Converse payloads used by the codec tests and the conformance suite."

  def text_response do
    %{
      "output" => %{"message" => %{"role" => "assistant", "content" => [%{"text" => "pong"}]}},
      "stopReason" => "end_turn",
      "usage" => %{"inputTokens" => 3, "outputTokens" => 5, "totalTokens" => 8}
    }
  end

  def tool_response do
    %{
      "output" => %{
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"toolUse" => %{"toolUseId" => "t1", "name" => "get", "input" => %{"a" => 1}}}
          ]
        }
      },
      "stopReason" => "tool_use",
      "usage" => %{"inputTokens" => 4, "outputTokens" => 6, "totalTokens" => 10}
    }
  end

  def error_payload do
    %{"message" => "no such model"}
  end
end
