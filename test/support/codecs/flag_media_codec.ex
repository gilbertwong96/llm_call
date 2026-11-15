defmodule LlmDialect.TestCodec.FlagMedia do
  @moduledoc """
  Media codec fake that declares `seed: true` and rejects every seed, so the flag check must catch it.
  """
  # Declares seed: true but rejects every seed, so the capability-consistency
  # check must catch the mismatch.
  @behaviour LlmDialect.Media.Codec

  alias LlmDialect.{Codec, Error}
  alias LlmDialect.Media.Capabilities, as: MediaCapabilities
  alias LlmDialect.Media.Request, as: MediaRequest

  @impl true
  def info, do: %Codec.Info{name: :flag_media, protocol: :flag_media, ir_version: 1}

  @impl true
  def capabilities(_request, _config), do: %MediaCapabilities{modalities: [:image], seed: true}

  @impl true
  def validate_request(%MediaRequest{params: params}, _config) do
    cond do
      Map.has_key?(params, :n) ->
        {:error, %Error{kind: :validation, message: "flag_media: n"}}

      Map.has_key?(params, :seed) ->
        {:error, %Error{kind: :validation, message: "flag_media: seed"}}

      true ->
        :ok
    end
  end

  @impl true
  def encode_submit(_request, _config), do: {:ok, %LlmDialect.EncodedRequest{path: "/flag"}}

  @impl true
  def decode_submit(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "flag_media"}}

  @impl true
  def decode_error(_term, _config), do: %Error{kind: :provider, message: "flag_media"}
end
