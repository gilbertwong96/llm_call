defmodule LlmCall.StreamEvent do
  @moduledoc """
  A normalized streaming event.

  `delta` is a closed union of `LlmCall.StreamDelta` structs, so callers never
  pattern-match provider JSON. `raw` holds the provider event only when
  `LlmCall.Config.capture_raw` is `:all`.
  """

  @type type ::
          :message_start
          | :content_start
          | :text_delta
          | :tool_call_start
          | :tool_call_delta
          | :tool_call_stop
          | :thinking_delta
          | :content_stop
          | :message_delta
          | :message_stop
          | :error

  @type index :: non_neg_integer() | nil

  @type delta ::
          nil
          | %LlmCall.StreamDelta.Text{text: String.t()}
          | %LlmCall.StreamDelta.ToolCall{
              id: String.t() | nil,
              name: String.t() | nil,
              arguments: String.t() | nil,
              index: index()
            }
          | %LlmCall.StreamDelta.Thinking{
              text: String.t(),
              signature: String.t() | nil
            }
          | %LlmCall.StreamDelta.MessageDelta{
              stop_reason: LlmCall.stop_reason() | nil,
              usage: LlmCall.Usage.t() | nil
            }
          | %LlmCall.StreamDelta.Raw{data: map()}

  @type raw :: map() | nil

  @type t :: %__MODULE__{
          type: type(),
          index: index(),
          delta: delta(),
          raw: raw()
        }

  defstruct [:type, :index, :delta, :raw]
end
