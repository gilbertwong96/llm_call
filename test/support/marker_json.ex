defmodule LlmCall.MarkerJSON do
  @moduledoc """
  JSON test double that prefixes encoded strings with a marker.

  A codec that hardcodes `LlmCall.JSON` instead of using `Config.json` produces
  byte-identical output under the default, so the audits cannot see a missed
  forward. Encoding through this module and asserting the marker proves the
  configured implementation reached the codec.
  """

  @behaviour LlmCall.JSON

  @marker "MARKER:"

  @impl true
  def encode(term) do
    with {:ok, encoded} <- LlmCall.JSON.encode(term), do: {:ok, @marker <> encoded}
  end

  @impl true
  def decode(binary) when is_binary(binary) do
    case String.split(binary, @marker, parts: 2) do
      [_prefix, payload] -> LlmCall.JSON.decode(payload)
      [payload] -> LlmCall.JSON.decode(payload)
    end
  end

  def decode(other), do: LlmCall.JSON.decode(other)
end
