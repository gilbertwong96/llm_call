defmodule LlmCall.StreamState do
  @moduledoc """
  Opaque per-codec streaming state.

  The public API checks `codec/1` before delegating, so a state produced by one
  codec cannot be fed to another. Codecs read their private data with `data/1`
  and build a new state with `new/2`.
  """

  @opaque t :: %__MODULE__{codec: module(), data: term()}

  defstruct [:codec, :data]

  @spec new(module(), term()) :: t()
  def new(codec, data), do: %__MODULE__{codec: codec, data: data}

  @spec codec(t()) :: module()
  def codec(%__MODULE__{codec: codec}), do: codec

  @spec data(t()) :: term()
  def data(%__MODULE__{data: data}), do: data
end
