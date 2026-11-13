defmodule LlmCall.TestCodec.BrokenAsyncMedia do
  @moduledoc """
  Media codec fake that declares `async: true` but omits `decode_operation/2`, so conformance must catch it.
  """
  # Declares async: true but does not implement decode_operation/2, so conformance
  # must catch it.
  @behaviour LlmCall.MediaCodec

  alias LlmCall.{Codec, Error, MediaCapabilities}

  @impl true
  def info,
    do: %Codec.Info{name: :broken_async_media, protocol: :broken_async_media, ir_version: 1}

  @impl true
  def capabilities(_request, _config), do: %MediaCapabilities{modalities: [:video], async: true}

  @impl true
  def validate_request(_request, _config), do: :ok

  @impl true
  def encode_submit(_request, _config), do: {:ok, %LlmCall.EncodedRequest{path: "/broken"}}

  @impl true
  def decode_submit(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "broken_async_media"}}

  @impl true
  def decode_error(_term, _config), do: %Error{kind: :provider, message: "broken_async_media"}
end
