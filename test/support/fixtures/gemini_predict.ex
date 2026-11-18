defmodule LlmCall.Media.Fixtures.GeminiPredict do
  @moduledoc """
  Gemini Imagen `predict` payloads shaped like the provider's responses.
  """

  def base64_response do
    %{"predictions" => [%{"bytesBase64Encoded" => "AAA", "mimeType" => "image/png"}]}
  end

  def jpeg_response do
    %{"predictions" => [%{"bytesBase64Encoded" => "BBB", "mimeType" => "image/jpeg"}]}
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
