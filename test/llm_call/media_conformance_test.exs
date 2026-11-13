defmodule LlmCall.MediaConformanceTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, MediaRequest, MediaResponse, Operation}
  alias LlmCall.MediaConformance

  defp codecs do
    [
      {LlmCall.Protocol.OpenAI.Images, "gpt-image-1",
       LlmCall.Fixtures.OpenAIImages.base64_response(), "/v1/images/generations"},
      {LlmCall.Protocol.Gemini.Predict, "imagen-4.0-generate-001",
       LlmCall.Fixtures.GeminiPredict.base64_response(),
       "/v1beta/models/imagen-4.0-generate-001:predict"}
    ]
  end

  defp request(model) do
    %MediaRequest{modality: :image, model: model, prompt: "a cat"}
  end

  test "every media codec satisfies the conformance contract" do
    for {codec, model, response, path} <- codecs() do
      assert :ok = MediaConformance.assert_info(codec)
      assert :ok = MediaConformance.assert_capabilities(codec, request(model), %Config{})
      assert :ok = MediaConformance.assert_submit_path(codec, request(model), path)
      assert :ok = MediaConformance.assert_capture_raw(codec, response)
      assert :ok = MediaConformance.assert_sync_rejects_operation(codec)
    end
  end

  test "conformance assertions catch a violating codec" do
    codec = LlmCall.Protocol.OpenAI.Images

    assert_raise ExUnit.AssertionError, fn ->
      MediaConformance.assert_submit_path(codec, request("gpt-image-1"), "/wrong")
    end

    assert_raise ExUnit.AssertionError, fn ->
      MediaConformance.assert_capture_raw(codec, %{"nope" => 1})
    end
  end

  test "an async declaration without decode_operation/2 is caught" do
    assert_raise ExUnit.AssertionError, ~r/decode_operation/, fn ->
      MediaConformance.assert_capabilities(
        LlmCall.TestCodec.BrokenAsyncMedia,
        request("fake-1"),
        %Config{}
      )
    end
  end

  test "assert_operation/1 accepts every legal state" do
    poll = %LlmCall.EncodedRequest{method: :get, path: "/jobs/1"}

    for operation <- [
          %Operation{status: :queued, next: poll, next_kind: :poll},
          %Operation{status: :in_progress, progress: 40, next: poll, next_kind: :poll},
          %Operation{
            status: :completed,
            result: %MediaResponse{assets: []},
            next: poll,
            next_kind: :asset,
            next_media_type: "video/mp4"
          },
          %Operation{
            status: :completed,
            result: %MediaResponse{assets: [%LlmCall.Content.Video{source: {:url, "u"}}]}
          },
          %Operation{status: :failed, error: %LlmCall.Error{kind: :provider, message: "boom"}}
        ] do
      assert :ok = MediaConformance.assert_operation(operation)
    end
  end

  test "assert_operation/1 rejects illegal states" do
    poll = %LlmCall.EncodedRequest{method: :get, path: "/jobs/1"}

    for operation <- [
          %Operation{status: :completed, next: poll, next_kind: :poll, result: %MediaResponse{}},
          %Operation{status: :completed, next: poll, next_kind: :asset, result: %MediaResponse{}},
          %Operation{status: :completed, next_kind: :asset, next_media_type: "video/mp4"},
          %Operation{status: :in_progress},
          %Operation{status: :failed, next: poll},
          %Operation{
            status: :failed,
            error: %LlmCall.Error{kind: :provider, message: "x"},
            result: %MediaResponse{}
          }
        ] do
      assert_raise ExUnit.AssertionError, fn -> MediaConformance.assert_operation(operation) end
    end
  end

  test "assert_capability_consistency/3 accepts declared values on the M1 codecs" do
    assert :ok =
             MediaConformance.assert_capability_consistency(
               LlmCall.Protocol.OpenAI.Images,
               %MediaRequest{modality: :image, model: "gpt-image-1", prompt: "a cat"},
               %Config{}
             )

    assert :ok =
             MediaConformance.assert_capability_consistency(
               LlmCall.Protocol.Gemini.Predict,
               %MediaRequest{modality: :image, model: "imagen-4.0-generate-001", prompt: "a cat"},
               %Config{}
             )
  end

  test "assert_capability_consistency/3 catches a declaration validation does not honour" do
    assert_raise ExUnit.AssertionError, fn ->
      MediaConformance.assert_capability_consistency(
        LlmCall.TestCodec.FakeMedia,
        %MediaRequest{modality: :image, model: "fake-1", prompt: "a cat"},
        %Config{}
      )
    end
  end
end
