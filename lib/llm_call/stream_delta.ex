defmodule LlmCall.StreamDelta.Text do
  @moduledoc "Incremental text."

  @type t :: %__MODULE__{text: String.t()}

  defstruct [:text]
end

defmodule LlmCall.StreamDelta.ToolCall do
  @moduledoc """
  A tool-call fragment.

  `arguments` is the argument JSON as received; it may be a partial fragment
  until the call stops. `LlmCall.StreamAssembler` turns a fragment sequence into
  a complete `LlmCall.ToolCall`.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          arguments: String.t() | nil,
          index: non_neg_integer() | nil
        }

  defstruct [:id, :name, :arguments, :index]
end

defmodule LlmCall.StreamDelta.Thinking do
  @moduledoc """
  Incremental reasoning text, a reasoning signature, or both.

  A provider streams the text as it is generated and the signature at the end of the
  block, in an event whose `text` is `""`. Folding only `text` silently loses the
  signature, and the finished block then cannot be replayed: a provider rejects it,
  and this library reports a `:validation` error first. Take whichever field the
  event carries:

      def merge(%LlmCall.Content.Thinking{} = block, %__MODULE__{} = delta) do
        %{block | text: block.text <> delta.text, signature: delta.signature || block.signature}
      end
  """

  @type t :: %__MODULE__{
          text: String.t(),
          signature: String.t() | nil
        }

  defstruct [:text, :signature]
end

defmodule LlmCall.StreamDelta.MessageDelta do
  @moduledoc "A stop reason, usage, or both, arriving mid-stream."

  @type t :: %__MODULE__{
          stop_reason: LlmCall.stop_reason() | nil,
          usage: LlmCall.Usage.t() | nil
        }

  defstruct [:stop_reason, :usage]
end

defmodule LlmCall.StreamDelta.Raw do
  @moduledoc "A provider payload the codec did not map to a canonical delta."

  @type t :: %__MODULE__{data: map()}

  defstruct [:data]
end
