defmodule LlmCall.Media.Protocol.ConformanceTest do
  @moduledoc """
  Runs the core conformance suite over every adapter this package ships.

  A package that cannot pass these is not publishable: they are the same
  assertions core runs over its reference adapters.
  """

  use ExUnit.Case, async: true

  alias LlmCall.{Config, MediaRequest, MediaResponse}
  alias LlmCall.MediaConformance
  alias LlmCall.Media.Fixtures.{GeminiPredict, MiniMaxVideo, OpenAIImages, SeedanceVideo}

  defp request(modality, model) do
    %MediaRequest{modality: modality, model: model, prompt: "a cat"}
  end

  test "every synchronous media codec satisfies the conformance contract" do
    for {codec, model, response, path} <- [
          {LlmCall.Media.Protocol.OpenAI.Images, "gpt-image-1", OpenAIImages.base64_response(),
           "/v1/images/generations"},
          {LlmCall.Media.Protocol.Gemini.Predict, "imagen-4.0-generate-001",
           GeminiPredict.base64_response(), "/v1beta/models/imagen-4.0-generate-001:predict"}
        ] do
      request = request(:image, model)

      assert :ok = MediaConformance.assert_info(codec)
      assert :ok = MediaConformance.assert_capabilities(codec, request, %Config{})
      assert :ok = MediaConformance.assert_submit_path(codec, request, path)
      assert :ok = MediaConformance.assert_capture_raw(codec, response)
      assert :ok = MediaConformance.assert_capability_consistency(codec, request, %Config{})
      assert :ok = MediaConformance.assert_sync_rejects_operation(codec)
    end
  end

  test "every asynchronous media codec satisfies the operation contract" do
    for {codec, model, submit, poll, path} <- [
          {LlmCall.Media.Protocol.Seedance.Video, "seedance-1-5-pro-251215",
           SeedanceVideo.submit_response(), SeedanceVideo.running_response(),
           "/api/v3/contents/generations/tasks"},
          {LlmCall.Media.Protocol.MiniMax.Video, "MiniMax-Hailuo-2.3",
           MiniMaxVideo.submit_response(), MiniMaxVideo.processing_response(),
           "/v1/video_generation"}
        ] do
      request = request(:video, model)

      assert :ok = MediaConformance.assert_info(codec)
      assert :ok = MediaConformance.assert_capabilities(codec, request, %Config{})
      assert :ok = MediaConformance.assert_submit_path(codec, request, path)
      assert :ok = MediaConformance.assert_capability_consistency(codec, request, %Config{})

      assert {:ok, %MediaResponse{assets: [], operation: operation}} =
               codec.decode_submit(submit, %Config{})

      assert :ok = MediaConformance.assert_operation(operation)

      assert {:ok, poll_operation} = codec.decode_operation(poll, %Config{})
      assert :ok = MediaConformance.assert_operation(poll_operation)
      assert poll_operation.next_kind == :poll
    end
  end
end
