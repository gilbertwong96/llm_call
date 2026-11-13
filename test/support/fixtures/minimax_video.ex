defmodule LlmCall.Media.Fixtures.MiniMaxVideo do
  @moduledoc """
  MiniMax Hailuo payloads, including the `base_resp` error envelopes.
  """

  defp ok, do: %{"status_code" => 0, "status_msg" => "success"}

  def submit_response, do: %{"task_id" => "task_123", "base_resp" => ok()}

  def preparing_response,
    do: %{"task_id" => "task_123", "status" => "Preparing", "base_resp" => ok()}

  def queueing_response,
    do: %{"task_id" => "task_123", "status" => "Queueing", "base_resp" => ok()}

  def processing_response,
    do: %{"task_id" => "task_123", "status" => "Processing", "base_resp" => ok()}

  def success_response do
    %{"task_id" => "task_123", "status" => "Success", "file_id" => "987654", "base_resp" => ok()}
  end

  def success_without_file_response do
    %{"task_id" => "task_123", "status" => "Success", "base_resp" => ok()}
  end

  def fail_response do
    %{
      "task_id" => "task_123",
      "status" => "Fail",
      "base_resp" => %{"status_code" => 1027, "status_msg" => "Output content error"}
    }
  end

  def retrieve_response do
    %{
      "file" => %{
        "file_id" => 987_654,
        "download_url" => "https://files.example/v.mp4",
        "purpose" => "video_generation"
      },
      "base_resp" => ok()
    }
  end

  def error_payload do
    %{"base_resp" => %{"status_code" => 1008, "status_msg" => "Insufficient balance"}}
  end

  def rate_limit_payload do
    %{"base_resp" => %{"status_code" => 1002, "status_msg" => "RPM limit triggered"}}
  end

  def submit_error_response do
    %{
      "task_id" => "",
      "base_resp" => %{"status_code" => 1008, "status_msg" => "Insufficient balance"}
    }
  end

  def query_error_response do
    %{"task_id" => "task_123", "base_resp" => %{"status_code" => 1001, "status_msg" => "Timeout"}}
  end

  def retrieve_error_response do
    %{
      "file" => nil,
      "base_resp" => %{"status_code" => 1004, "status_msg" => "Authentication failed"}
    }
  end
end
