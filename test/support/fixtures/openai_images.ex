defmodule LlmCall.Fixtures.OpenAIImages do
  @moduledoc false

  def base64_response do
    %{
      "created" => 1,
      "data" => [
        %{"b64_json" => "AAA", "revised_prompt" => "a fluffy cat"},
        %{"url" => "https://example.com/a.png"}
      ],
      "usage" => %{"input_tokens" => 12, "output_tokens" => 4, "total_tokens" => 16}
    }
  end

  def error_payload do
    %{
      "error" => %{
        "message" => "Billing hard limit reached",
        "type" => "billing_hard_limit_reached",
        "code" => "billing_hard_limit_reached"
      }
    }
  end
end
