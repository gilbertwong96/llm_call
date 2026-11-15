defmodule LlmDialect.Media.Response do
  @moduledoc """
  The result of a media generation.

  A synchronous codec fills `assets`. An asynchronous codec leaves `assets` empty
  and returns an `operation`; progress arrives through
  `LlmDialect.decode_operation/3` and the core never polls for it.
  """

  @type asset :: LlmDialect.Content.Image.t() | LlmDialect.Content.Video.t()

  @type t :: %__MODULE__{
          assets: [asset()],
          revised_prompt: String.t() | nil,
          usage: LlmDialect.Usage.t() | nil,
          operation: LlmDialect.Operation.t() | nil,
          raw: map() | nil
        }

  defstruct assets: [], revised_prompt: nil, usage: nil, operation: nil, raw: nil
end
