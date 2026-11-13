defmodule LlmCall.Fixtures.GeminiPredict do
  @moduledoc false

  def base64_response do
    %{"predictions" => [%{"bytesBase64Encoded" => "AAA", "mimeType" => "image/png"}]}
  end

  def filtered_response do
    %{"predictions" => [%{"raiFilteredReason" => "Blocked by safety filters"}]}
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
end
