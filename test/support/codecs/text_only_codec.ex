defmodule LlmDialect.TestCodec.TextOnly do
  @moduledoc """
  Completion codec fake without streaming callbacks, used to check the typed 'does not support' error.
  """
  @behaviour LlmDialect.Codec

  alias LlmDialect.{Capabilities, Codec, EncodedRequest, Error, Response}

  @impl true
  def info, do: %Codec.Info{name: :text_only, protocol: :text_only, version: nil, ir_version: 1}

  @impl true
  def validate_request(_request, _config), do: :ok

  @impl true
  def encode_request(request, _config),
    do: {:ok, %EncodedRequest{path: "/text-only", body: %{"model" => request.model}}}

  @impl true
  def decode_response(%{"text" => text}, _config),
    do: {:ok, %Response{content: [%LlmDialect.Content.Text{text: text}]}}

  def decode_response(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "text_only: bad payload"}}

  @impl true
  def decode_error(_term, _config), do: %Error{kind: :provider, message: "text_only error"}

  @impl true
  def capabilities(_request, _config), do: %Capabilities{streaming: false}
end
