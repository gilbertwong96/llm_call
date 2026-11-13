defmodule LlmCall.Protocol.OpenAIImagesTest do
  use ExUnit.Case, async: true

  alias LlmCall.Protocol.OpenAI.Images
  alias LlmCall.{Config, Content, Error, MediaRequest, MediaResponse}
  alias LlmCall.Fixtures.OpenAIImages, as: Fx

  defp request(overrides \\ []) do
    struct(%MediaRequest{modality: :image, model: "gpt-image-1", prompt: "a cat"}, overrides)
  end

  test "info/0 declares the protocol and IR version" do
    assert %LlmCall.Codec.Info{name: :openai_images, protocol: :openai_images, ir_version: 1} =
             Images.info()
  end

  test "encodes a minimal image request" do
    assert {:ok, encoded} = Images.encode_submit(request(), %Config{})
    assert encoded.method == :post
    assert encoded.path == "/v1/images/generations"
    assert encoded.query == %{}
    assert encoded.headers == [{"content-type", "application/json"}]

    assert encoded.body == %{"model" => "gpt-image-1", "prompt" => "a cat"}
  end

  test "response_format is only sent to models that accept it" do
    refute Map.has_key?(encode_body(request()), "response_format")
    assert encode_body(request(model: "dall-e-3"))["response_format"] == "b64_json"

    assert encode_body(
             request(
               model: "dall-e-3",
               provider_options: %{openai: %{"response_format" => "url"}}
             )
           )["response_format"] == "url"
  end

  test "nil knobs mean the provider default and are accepted" do
    assert :ok = Images.validate_request(request(params: %{size: nil, n: nil}), %Config{})
    assert :ok = Images.validate_request(request(references: nil), %Config{})
    assert :ok = Images.validate_request(request(params: %{aspect_ratio: nil}), %Config{})
  end

  test "n and size map to native fields" do
    body = encode_body(request(params: %{n: 2, size: "1024x1024"}))
    assert body["n"] == 2
    assert body["size"] == "1024x1024"
  end

  test "provider_options merge deeply but cannot replace canonical fields" do
    body = encode_body(request(provider_options: %{openai: %{"user" => "u1"}}))
    assert body["user"] == "u1"

    for key <- ["model", "prompt", "instances", "parameters", "modality"] do
      assert {:error, %Error{kind: :validation}} =
               Images.encode_submit(
                 request(provider_options: %{openai: %{key => "x"}}),
                 %Config{}
               )
    end
  end

  test "unsupported knobs and references are validation errors, never silent drops" do
    for request <- [
          request(modality: :video),
          request(params: %{aspect_ratio: "1:1"}),
          request(params: %{duration_s: 5}),
          request(params: %{seed: 1}),
          request(params: %{negative_prompt: "ugly"}),
          request(params: %{n: 0}),
          request(params: %{n: 11}),
          request(params: %{size: "7x7"}),
          request(references: [%Content.Image{source: {:url, "u"}}]),
          %MediaRequest{modality: :image, model: "gpt-image-1"},
          %MediaRequest{modality: :image, prompt: "a cat"}
        ] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Images.validate_request(request, %Config{})

      assert is_binary(message)
      assert {:error, %Error{kind: :validation}} = Images.encode_submit(request, %Config{})
    end
  end

  test "capabilities declare the image surface" do
    assert %LlmCall.MediaCapabilities{
             modalities: [:image],
             async: false,
             max_n: 10,
             sizes: sizes,
             aspect_ratios: [],
             durations_s: [],
             references: false,
             seed: false,
             negative_prompt: false
           } = Images.capabilities(request(), %Config{})

    assert "1024x1024" in sizes
    assert "auto" in sizes
  end

  test "decodes base64 and url assets plus usage" do
    assert {:ok,
            %MediaResponse{
              assets: assets,
              revised_prompt: "a fluffy cat",
              usage: usage,
              raw: nil
            }} = Images.decode_submit(Fx.base64_response(), %Config{})

    assert [
             %Content.Image{source: {:base64, "AAA"}, media_type: "image/png"},
             %Content.Image{source: {:url, "https://example.com/a.png"}, media_type: nil}
           ] = assets

    assert %LlmCall.Usage{input_tokens: 12, output_tokens: 4, total_tokens: 16} = usage
  end

  test "capture_raw keeps the payload only when asked" do
    payload = Fx.base64_response()

    assert {:ok, %MediaResponse{raw: nil}} = Images.decode_submit(payload, %Config{})

    assert {:ok, %MediaResponse{raw: ^payload}} =
             Images.decode_submit(payload, %Config{capture_raw: :response})
  end

  test "a payload with no assets is an invalid response, not an empty success" do
    assert {:error, %Error{kind: :invalid_response}} =
             Images.decode_submit(%{"data" => []}, %Config{})

    assert {:error, %Error{kind: :invalid_response}} =
             Images.decode_submit(%{"nope" => 1}, %Config{})

    assert {:error, %Error{kind: :invalid_response}} =
             Images.decode_submit(%{"data" => [%{}]}, %Config{})
  end

  test "decode_error/2 normalizes the provider envelope" do
    payload = Fx.error_payload()

    assert %Error{
             kind: :provider,
             message: "Billing hard limit reached",
             code: "billing_hard_limit_reached",
             retryable?: false,
             raw: ^payload
           } = Images.decode_error(payload, %Config{})

    assert %Error{kind: :invalid_response} = Images.decode_error("boom", %Config{})
  end

  defp encode_body(request) do
    assert {:ok, encoded} = Images.encode_submit(request, %Config{})
    encoded.body
  end
end
