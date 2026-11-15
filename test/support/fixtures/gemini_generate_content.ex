defmodule LlmDialect.Fixtures.GeminiGenerateContent do
  @moduledoc """
  Gemini GenerateContent payloads shaped like the provider's responses.
  """

  def text_response do
    %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => "Hello"}]},
          "finishReason" => "STOP",
          "index" => 0
        }
      ],
      "usageMetadata" => %{
        "promptTokenCount" => 12,
        "candidatesTokenCount" => 5,
        "totalTokenCount" => 17,
        "cachedContentTokenCount" => 3,
        "thoughtsTokenCount" => 2
      },
      "modelVersion" => "gemini-2.5-pro",
      "responseId" => "resp-1"
    }
  end

  def tool_response do
    %{
      "candidates" => [
        %{
          "content" => %{
            "role" => "model",
            "parts" => [
              %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "Oslo"}}}
            ]
          },
          "finishReason" => "STOP",
          "index" => 0
        }
      ],
      "modelVersion" => "gemini-2.5-pro",
      "responseId" => "resp-2"
    }
  end

  def mixed_response do
    %{
      "candidates" => [
        %{
          "content" => %{
            "role" => "model",
            "parts" => [
              %{"text" => "hmm", "thought" => true, "thoughtSignature" => "ts"},
              %{"text" => "Hi"},
              %{"inlineData" => %{"mimeType" => "image/png", "data" => "AAA"}},
              %{"executableCode" => %{"code" => "1"}}
            ]
          },
          "finishReason" => "STOP",
          "index" => 0
        }
      ],
      "modelVersion" => "gemini-2.5-pro",
      "responseId" => "resp-3"
    }
  end

  def response_with_finish(finish_reason) do
    put_in(text_response(), ["candidates", Access.at(0), "finishReason"], finish_reason)
  end

  def blocked_response do
    %{
      "promptFeedback" => %{"blockReason" => "SAFETY"},
      "usageMetadata" => %{"promptTokenCount" => 4, "totalTokenCount" => 4},
      "modelVersion" => "gemini-2.5-pro",
      "responseId" => "resp-4"
    }
  end

  def two_candidates_response do
    %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => "first"}]},
          "finishReason" => "STOP",
          "index" => 0
        },
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => "second"}]},
          "finishReason" => "STOP",
          "index" => 1
        }
      ],
      "modelVersion" => "gemini-2.5-pro",
      "responseId" => "resp-5"
    }
  end

  def error_payload do
    %{
      "error" => %{
        "code" => 429,
        "message" => "Quota exceeded",
        "status" => "RESOURCE_EXHAUSTED"
      }
    }
  end

  def text_chunk(text) do
    %{
      "candidates" => [
        %{"content" => %{"role" => "model", "parts" => [%{"text" => text}]}, "index" => 0}
      ]
    }
  end

  def text_chunks do
    [
      text_chunk("Hel"),
      text_chunk("lo"),
      %{
        "candidates" => [%{"finishReason" => "STOP", "index" => 0}],
        "usageMetadata" => %{
          "promptTokenCount" => 12,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 17
        },
        "modelVersion" => "gemini-2.5-pro",
        "responseId" => "resp-6"
      }
    ]
  end

  def tool_chunks do
    [
      %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [
                %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "Oslo"}}}
              ]
            },
            "index" => 0
          }
        ]
      }
    ]
  end

  def two_tool_chunks do
    [
      %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [%{"functionCall" => %{"name" => "a", "args" => %{"x" => 1}}}]
            },
            "index" => 0
          }
        ]
      },
      %{
        "candidates" => [
          %{
            "content" => %{
              "role" => "model",
              "parts" => [%{"functionCall" => %{"name" => "b", "args" => %{"x" => 2}}}]
            },
            "index" => 0
          }
        ]
      }
    ]
  end

  def thought_chunk do
    %{
      "candidates" => [
        %{
          "content" => %{
            "role" => "model",
            "parts" => [%{"text" => "hmm", "thought" => true}]
          },
          "index" => 0
        }
      ]
    }
  end
end
