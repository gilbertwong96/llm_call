defmodule LlmCallMedia.Protocol.GeminiPredictTest do
  use ExUnit.Case, async: true

  alias LlmCallMedia.Protocol.Gemini.Predict
  alias LlmCall.{Config, Content, Error, MediaRequest, MediaResponse}
  alias LlmCallMedia.Fixtures.GeminiPredict, as: Fx

  defp request(overrides \\ []) do
    struct(
      %MediaRequest{modality: :image, model: "imagen-4.0-generate-001", prompt: "a cat"},
      overrides
    )
  end

  test "info/0 carries the Gemini API version" do
    assert %LlmCall.Codec.Info{
             name: :gemini_predict,
             protocol: :gemini_predict,
             version: "v1beta",
             ir_version: 1
           } = Predict.info()
  end

  test "encodes instances and parameters" do
    assert {:ok, encoded} = Predict.encode_submit(request(), %Config{})
    assert encoded.method == :post
    assert encoded.path == "/v1beta/models/imagen-4.0-generate-001:predict"
    assert encoded.query == %{}
    assert encoded.headers == [{"content-type", "application/json"}]
    assert encoded.body == %{"instances" => [%{"prompt" => "a cat"}]}

    body = encode_body(request(params: %{n: 2, aspect_ratio: "16:9", negative_prompt: "ugly"}))

    assert body["parameters"] == %{
             "sampleCount" => 2,
             "aspectRatio" => "16:9",
             "negativePrompt" => "ugly"
           }
  end

  test "unsupported knobs and references are validation errors" do
    for request <- [
          request(modality: :video),
          request(params: %{size: "1024x1024"}),
          request(params: %{duration_s: 5}),
          request(params: %{seed: 1}),
          request(params: %{n: 0}),
          request(params: %{n: 5}),
          request(params: %{aspect_ratio: "7:3"}),
          request(references: [%Content.Image{source: {:url, "u"}}]),
          request(model: "models/imagen"),
          %MediaRequest{modality: :image, model: "imagen", prompt: ""}
        ] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Predict.validate_request(request, %Config{})

      assert is_binary(message)
      assert {:error, %Error{kind: :validation}} = Predict.encode_submit(request, %Config{})
    end
  end

  test "native parameters merge through provider_options" do
    body =
      encode_body(
        request(
          provider_options: %{gemini: %{"parameters" => %{"personGeneration" => "dont_allow"}}}
        )
      )

    assert body["parameters"] == %{"personGeneration" => "dont_allow"}

    body =
      encode_body(
        request(
          params: %{n: 2},
          provider_options: %{gemini: %{"parameters" => %{"personGeneration" => "dont_allow"}}}
        )
      )

    assert body["parameters"] == %{"sampleCount" => 2, "personGeneration" => "dont_allow"}
  end

  test "nil knobs mean the provider default and are accepted" do
    assert :ok = Predict.validate_request(request(params: %{size: nil, seed: nil}), %Config{})
    assert :ok = Predict.validate_request(request(references: nil), %Config{})
  end

  test "capabilities declare the image surface" do
    assert %LlmCall.MediaCapabilities{
             modalities: [:image],
             async: false,
             max_n: 4,
             sizes: [],
             aspect_ratios: aspect_ratios,
             durations_s: [],
             references: false,
             seed: false,
             negative_prompt: true
           } = Predict.capabilities(request(), %Config{})

    assert "16:9" in aspect_ratios
  end

  test "decodes predictions into base64 images" do
    assert {:ok,
            %MediaResponse{
              assets: [%Content.Image{source: {:base64, "AAA"}, media_type: "image/png"}],
              operation: nil,
              raw: nil
            }} = Predict.decode_submit(Fx.base64_response(), %Config{})
  end

  test "a filtered prediction is a provider error" do
    assert {:error, %Error{kind: :provider, message: "Blocked by safety filters"}} =
             Predict.decode_submit(Fx.filtered_response(), %Config{})
  end

  test "a partially filtered response keeps its usable assets" do
    payload = %{
      "predictions" => [
        %{"raiFilteredReason" => "Blocked by safety filters"},
        %{"bytesBase64Encoded" => "AAA", "mimeType" => "image/png"}
      ]
    }

    assert {:ok, %MediaResponse{assets: [%Content.Image{source: {:base64, "AAA"}}]}} =
             Predict.decode_submit(payload, %Config{})
  end

  test "capture_raw and invalid payloads" do
    payload = Fx.base64_response()

    assert {:ok, %MediaResponse{raw: ^payload}} =
             Predict.decode_submit(payload, %Config{capture_raw: :all})

    assert {:error, %Error{kind: :invalid_response}} =
             Predict.decode_submit(%{"nope" => 1}, %Config{})

    assert {:error, %Error{kind: :invalid_response}} =
             Predict.decode_submit(%{"predictions" => []}, %Config{})

    assert {:error, %Error{kind: :invalid_response}} =
             Predict.decode_submit(%{"predictions" => [%{"mimeType" => "image/png"}]}, %Config{})
  end

  test "decode_error/2 normalizes the Google envelope" do
    payload = Fx.error_payload()

    assert %Error{
             kind: :provider,
             message: "Quota exceeded",
             code: "RESOURCE_EXHAUSTED",
             status: 429,
             retryable?: true,
             raw: ^payload
           } = Predict.decode_error(payload, %Config{})

    assert %Error{kind: :invalid_response} = Predict.decode_error(%{"weird" => 1}, %Config{})
  end

  defp encode_body(request) do
    assert {:ok, encoded} = Predict.encode_submit(request, %Config{})
    encoded.body
  end
end
