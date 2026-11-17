defmodule LlmDialect.JSON do
  @moduledoc """
  JSON encoding for the few wire fields that are themselves JSON strings.

  OpenAI Chat tool-call arguments and Gemini stream function calls carry their
  arguments as an encoded string, so a codec must be able to produce one. This
  wraps OTP's `:json` module, which ships with Erlang: the core still has no JSON
  dependency and every other field stays a term.

  Decoding is deliberately absent. A codec decodes a provider's argument string
  with `:json.decode/1` in a `try`, because malformed arguments must become
  `{:invalid_json, raw}` rather than raise.
  """

  @doc """
  Encodes a term as a JSON string.

  Raises when the term is not JSON-encodable (an atom value, a tuple, a PID);
  callers that accept caller-supplied data validate it first.

      iex> LlmDialect.JSON.encode(%{"city" => "Oslo"})
      ~s({"city":"Oslo"})
  """

  @spec encode(term()) :: String.t()
  def encode(term), do: term |> :json.encode() |> IO.iodata_to_binary()

  @doc """
  True when `LlmDialect.JSON.encode/1` accepts the term.
  """
  @spec encodable?(term()) :: boolean()
  def encodable?(term) do
    _encoded = encode(term)
    true
  rescue
    _error -> false
  end
end
