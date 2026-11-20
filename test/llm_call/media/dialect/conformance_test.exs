defmodule LlmCall.Media.Dialect.ConformanceTest do
  @moduledoc """
  Runs the core conformance suite over every adapter this package ships.

  A package that cannot pass these is not publishable: they are the same
  assertions core runs over its reference adapters.
  """

  use ExUnit.Case, async: true

  alias LlmCall.Config
  alias LlmCall.Media.Conformance
  alias LlmCall.Media.Fixtures.{GeminiPredict, MiniMaxVideo, OpenAIImages, SeedanceVideo}
  alias LlmCall.Media.Request, as: MediaRequest
  alias LlmCall.Media.Response, as: MediaResponse

  defp request(modality, model) do
    %MediaRequest{modality: modality, model: model, prompt: "a cat"}
  end

  test "every synchronous media codec satisfies the conformance contract" do
    for {codec, model, response, path} <- [
          {LlmCall.Media.Dialect.OpenAI.Images, "gpt-image-1", OpenAIImages.base64_response(),
           "/v1/images/generations"},
          {LlmCall.Media.Dialect.Gemini.Predict, "imagen-4.0-generate-001",
           GeminiPredict.base64_response(), "/v1beta/models/imagen-4.0-generate-001:predict"}
        ] do
      request = request(:image, model)

      assert :ok = Conformance.assert_info(codec)
      assert :ok = Conformance.assert_capabilities(codec, request, %Config{})
      assert :ok = Conformance.assert_submit_path(codec, request, path)
      assert :ok = Conformance.assert_capture_raw(codec, response)
      assert :ok = Conformance.assert_capability_consistency(codec, request, %Config{})
      assert :ok = Conformance.assert_sync_rejects_operation(codec)
    end
  end

  test "capability declarations expose the reference cap" do
    assert %LlmCall.Media.Capabilities{max_references: 2, max_n: :unsupported} =
             LlmCall.Media.Dialect.Seedance.Video.capabilities(
               %LlmCall.Media.Request{
                 modality: :video,
                 model: "seedance-1-5-pro-251215",
                 prompt: "a cat"
               },
               %Config{}
             )

    assert %LlmCall.Media.Capabilities{max_references: 1, max_n: :unsupported} =
             LlmCall.Media.Dialect.MiniMax.Video.capabilities(
               %LlmCall.Media.Request{
                 modality: :video,
                 model: "MiniMax-Hailuo-2.3",
                 prompt: "a cat"
               },
               %Config{}
             )

    assert %LlmCall.Media.Capabilities{max_n: 10, max_references: nil} =
             LlmCall.Media.Dialect.OpenAI.Images.capabilities(
               %LlmCall.Media.Request{modality: :image, model: "gpt-image-1", prompt: "a cat"},
               %Config{}
             )
  end

  test "a codec that does not declare a modality rejects it" do
    request = %LlmCall.Media.Request{
      modality: :image,
      model: "seedance-1-5-pro-251215",
      prompt: "a cat"
    }

    assert_raise ExUnit.AssertionError, ~r/modality/, fn ->
      LlmCall.Media.Conformance.assert_capabilities(
        LlmCall.Media.Dialect.Seedance.Video,
        request,
        %Config{}
      )
    end
  end

  test "every asynchronous media codec satisfies the operation contract" do
    for {codec, model, submit, poll, path} <- [
          {LlmCall.Media.Dialect.Seedance.Video, "seedance-1-5-pro-251215",
           SeedanceVideo.submit_response(), SeedanceVideo.running_response(),
           "/api/v3/contents/generations/tasks"},
          {LlmCall.Media.Dialect.MiniMax.Video, "MiniMax-Hailuo-2.3",
           MiniMaxVideo.submit_response(), MiniMaxVideo.processing_response(),
           "/v1/video_generation"}
        ] do
      request = request(:video, model)

      assert :ok = Conformance.assert_info(codec)
      assert :ok = Conformance.assert_capabilities(codec, request, %Config{})
      assert :ok = Conformance.assert_submit_path(codec, request, path)
      assert :ok = Conformance.assert_capability_consistency(codec, request, %Config{})

      assert {:ok, %MediaResponse{assets: [], operation: operation}} =
               codec.decode_submit(submit, %Config{})

      assert :ok = Conformance.assert_operation(operation)

      assert {:ok, poll_operation} = codec.decode_operation(poll, %Config{})
      assert :ok = Conformance.assert_operation(poll_operation)
      assert poll_operation.next_kind == :poll

      assert :ok = Conformance.assert_operation_capture_raw(codec, poll)
    end
  end

  test "a media provider error payload follows capture_raw" do
    for {codec, payload} <- [
          {LlmCall.Media.Dialect.OpenAI.Images, OpenAIImages.error_payload()},
          {LlmCall.Media.Dialect.Gemini.Predict, GeminiPredict.error_payload()},
          {LlmCall.Media.Dialect.Seedance.Video, SeedanceVideo.error_payload()},
          {LlmCall.Media.Dialect.MiniMax.Video, MiniMaxVideo.error_payload()}
        ] do
      assert %LlmCall.Error{kind: :provider, raw: nil} =
               codec.decode_error(payload, %Config{capture_raw: :none})

      assert %LlmCall.Error{kind: :provider, raw: ^payload} =
               codec.decode_error(payload, %Config{capture_raw: :response})
    end
  end
end
