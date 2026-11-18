defmodule LlmCall.Media.Fixtures.SeedanceVideo do
  @moduledoc """
  Seedance (BytePlus ModelArk) task payloads shaped like the provider's responses.
  """

  def submit_response, do: %{"id" => "cgt-2026-abc"}

  def queued_response do
    %{"id" => "cgt-2026-abc", "model" => "seedance-1-5-pro-251215", "status" => "queued"}
  end

  def running_response, do: %{"id" => "cgt-2026-abc", "status" => "running"}

  def succeeded_response do
    %{
      "id" => "cgt-2026-abc",
      "status" => "succeeded",
      "content" => %{"video_url" => "https://files.example/v.mp4"}
    }
  end

  def succeeded_without_url_response do
    %{"id" => "cgt-2026-abc", "status" => "succeeded", "content" => %{}}
  end

  def failed_response do
    %{
      "id" => "cgt-2026-abc",
      "status" => "failed",
      "error" => %{
        "code" => "OutputVideoSensitiveContentDetected",
        "message" => "Generation failed"
      }
    }
  end

  def cancelled_response, do: %{"id" => "cgt-2026-abc", "status" => "cancelled"}

  def expired_response, do: %{"id" => "cgt-2026-abc", "status" => "expired"}

  def error_payload do
    %{
      "error" => %{
        "code" => "InvalidParameter",
        "message" => "Invalid parameter",
        "type" => "BadRequest"
      }
    }
  end
end
