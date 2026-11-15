defmodule LlmDialect.StreamDelta.Text do
  @moduledoc "Incremental text."

  @type t :: %__MODULE__{text: String.t()}

  defstruct [:text]
end

defmodule LlmDialect.StreamDelta.ToolCall do
  @moduledoc """
  A tool-call fragment.

  `arguments` is the argument JSON as received; it may be a partial fragment
  until the call stops. `LlmDialect.StreamAssembler` turns a fragment sequence into
  a complete `LlmDialect.ToolCall`.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          arguments: String.t() | nil,
          index: non_neg_integer() | nil
        }

  defstruct [:id, :name, :arguments, :index]
end

defmodule LlmDialect.StreamDelta.Thinking do
  @moduledoc "Incremental reasoning text or a reasoning signature."

  @type t :: %__MODULE__{
          text: String.t(),
          signature: String.t() | nil
        }

  defstruct [:text, :signature]
end

defmodule LlmDialect.StreamDelta.MessageDelta do
  @moduledoc "A stop reason, usage, or both, arriving mid-stream."

  @type t :: %__MODULE__{
          stop_reason: LlmDialect.stop_reason() | nil,
          usage: LlmDialect.Usage.t() | nil
        }

  defstruct [:stop_reason, :usage]
end

defmodule LlmDialect.StreamDelta.Raw do
  @moduledoc "A provider payload the codec did not map to a canonical delta."

  @type t :: %__MODULE__{data: map()}

  defstruct [:data]
end
