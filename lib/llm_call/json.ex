defmodule LlmCall.JSON do
  @moduledoc """
  The JSON seam.

  `Config.json` is a module. The default is Elixir's built-in `JSON`, and any
  module exposing either the tagged or the bang API can be configured:

    * tagged: `encode/1` and `decode/1` returning `{:ok, value}` / `{:error, _}`
      (Torque, Jason, Poison, `LlmCall.JSON`);
    * bang: `encode!/1` and `decode!/1` (Elixir's `JSON`).

  The facade functions `encode/2` and `decode/2` dispatch on what the module
  exports and normalize the result to a tagged tuple, so a codec never raises on
  a malformed payload. Configure the module at compile time with
  `config :llm_call, json: Torque` (or the Phoenix-style
  `config :llm_call, json_library: Torque`) or per client with `json:`.

  A few wire fields are themselves JSON strings: tool-call arguments on OpenAI
  Chat, and streamed function calls on Gemini. A codec therefore needs a JSON
  implementation, and the caller may want a different one (Jason, a stricter
  encoder, a wrapped implementation with metrics).
  """

  @doc "Encodes a term with the configured module."
  @spec encode(module(), term()) :: {:ok, String.t()} | {:error, term()}
  def encode(module, term) do
    cond do
      exports?(module, :encode, 1) -> normalize_encode(module.encode(term))
      exports?(module, :encode!, 1) -> bang_encode(fn -> module.encode!(term) end)
      true -> {:error, {:missing_json_encoder, module}}
    end
  end

  @doc "Decodes a binary with the configured module."
  @spec decode(module(), String.t()) :: {:ok, term()} | {:error, term()}
  def decode(module, binary) when is_binary(binary) do
    cond do
      exports?(module, :decode, 1) -> normalize_decode(module.decode(binary))
      exports?(module, :decode!, 1) -> bang_decode(fn -> module.decode!(binary) end)
      true -> {:error, {:missing_json_decoder, module}}
    end
  end

  def decode(_module, other), do: {:error, {:not_a_binary, other}}

  @doc "The tagged adapter used by `LlmCall.JSON` itself, backed by Elixir `JSON`."
  @callback encode(term()) :: {:ok, String.t()} | {:error, term()}

  @doc "Decodes a JSON binary."
  @callback decode(String.t()) :: {:ok, term()} | {:error, term()}

  def encode(term) do
    {:ok, Elixir.JSON.encode!(term)}
  rescue
    error -> {:error, error}
  end

  def decode(binary) when is_binary(binary) do
    {:ok, Elixir.JSON.decode!(binary)}
  rescue
    error -> {:error, error}
  end

  def decode(other), do: {:error, {:not_a_binary, other}}

  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp bang_encode(fun) do
    normalize_encode({:ok, fun.()})
  rescue
    error -> {:error, error}
  end

  defp bang_decode(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  end

  defp normalize_encode({:ok, encoded}) when is_binary(encoded), do: {:ok, encoded}

  defp normalize_encode({:ok, encoded}) when is_list(encoded),
    do: {:ok, IO.iodata_to_binary(encoded)}

  defp normalize_encode({:error, _reason} = error), do: error
  defp normalize_encode(encoded) when is_binary(encoded), do: {:ok, encoded}
  defp normalize_encode(other), do: {:error, {:invalid_json_encoder_return, other}}

  defp normalize_decode({:ok, term}), do: {:ok, term}
  defp normalize_decode({:error, _reason} = error), do: error
  defp normalize_decode(term), do: {:ok, term}
end
