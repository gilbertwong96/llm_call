defmodule LlmCall.TestCodec.FakeMedia do
  @moduledoc false
  @behaviour LlmCall.MediaCodec

  alias LlmCall.{
    Codec,
    Content,
    EncodedRequest,
    Error,
    MediaCapabilities,
    MediaRequest,
    MediaResponse
  }

  @impl true
  def info, do: %Codec.Info{name: :fake_media, protocol: :fake_media, version: nil, ir_version: 1}

  @impl true
  def capabilities(_request, _config) do
    %MediaCapabilities{
      modalities: [:image],
      async: false,
      max_n: 4,
      sizes: ["1024x1024"],
      seed: true
    }
  end

  @impl true
  def validate_request(%MediaRequest{} = request, _config) do
    cond do
      request.modality != :image ->
        {:error, %Error{kind: :validation, message: "fake_media: modality"}}

      not is_binary(request.model) or request.model == "" ->
        {:error, %Error{kind: :validation, message: "fake_media: model"}}

      not is_binary(request.prompt) or request.prompt == "" ->
        {:error, %Error{kind: :validation, message: "fake_media: prompt"}}

      true ->
        :ok
    end
  end

  @impl true
  def encode_submit(%MediaRequest{} = request, config) do
    with :ok <- validate_request(request, config) do
      {:ok,
       %EncodedRequest{
         method: :post,
         path: "/fake/images",
         body: %{"prompt" => request.prompt}
       }}
    end
  end

  @impl true
  def decode_submit(%{"images" => images} = payload, config) do
    assets = Enum.map(images, &%Content.Image{source: {:base64, &1}, media_type: "image/png"})

    {:ok,
     %MediaResponse{
       assets: assets,
       revised_prompt: payload["revised_prompt"],
       raw: if(config.capture_raw == :none, do: nil, else: payload)
     }}
  end

  def decode_submit(term, _config) do
    {:error,
     %Error{
       kind: :invalid_response,
       message: "fake_media: bad payload",
       raw: %{"payload" => term}
     }}
  end

  @impl true
  def decode_error(%{"error" => %{"message" => message}} = payload, _config) do
    %Error{kind: :provider, message: message, raw: payload}
  end

  def decode_error(_term, _config),
    do: %Error{kind: :invalid_response, message: "fake_media: bad error"}
end
