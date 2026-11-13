defmodule LlmCall.MediaConformanceTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, MediaRequest}
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
end
