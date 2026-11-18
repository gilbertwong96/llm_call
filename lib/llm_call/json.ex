defmodule LlmCall.JSON do
  @moduledoc """
  The JSON seam.

  A few wire fields are themselves JSON strings: tool-call arguments on OpenAI
  Chat, and streamed function calls on Gemini. A codec therefore needs a JSON
  implementation, and the caller may want a different one (Jason, a stricter
  encoder, a wrapped implementation with metrics).

  This module defines the behaviour and is its default implementation, backed by
  OTP's `:json` (no dependency). Configure another one globally with
  `config :llm_call, json: Jason`, per provider with
  `use LlmCall.Provider, json: Jason`, or per client with `client(json: Jason)`.

  Both callbacks return tagged tuples: a codec turns `{:error, _}` into a typed
  `%LlmCall.Error{kind: :validation}`, and decoding a malformed provider fragment
  becomes `{:invalid_json, raw}` instead of a raise.
  """

  @doc "Encodes a term to a JSON string."
  @callback encode(term()) :: {:ok, String.t()} | {:error, term()}

  @doc "Decodes a JSON string."
  @callback decode(String.t()) :: {:ok, term()} | {:error, term()}

  @spec encode(term()) :: {:ok, String.t()} | {:error, term()}
  def encode(term) do
    {:ok, term |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    error -> {:error, error}
  end

  @spec decode(String.t()) :: {:ok, term()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    {:ok, :json.decode(binary)}
  rescue
    error -> {:error, error}
  end

  def decode(_other), do: {:error, :not_a_binary}
end
