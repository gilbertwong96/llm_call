defmodule LlmCall.MediaResponse do
  @moduledoc """
  The result of a media generation.

  A synchronous codec fills `assets`. An asynchronous codec leaves `assets` empty
  and returns an `operation`; progress arrives through
  `LlmCall.decode_operation/3` and the core never polls for it.
  """

  @type asset :: LlmCall.Content.Image.t() | LlmCall.Content.Video.t()

  @type t :: %__MODULE__{
          assets: [asset()],
          revised_prompt: String.t() | nil,
          usage: LlmCall.Usage.t() | nil,
          operation: LlmCall.Operation.t() | nil,
          raw: map() | nil
        }

  defstruct assets: [], revised_prompt: nil, usage: nil, operation: nil, raw: nil
end
