defmodule LlmDialect.StreamEvent do
  @moduledoc """
  A normalized streaming event.

  `delta` is a closed union of `LlmDialect.StreamDelta` structs, so callers never
  pattern-match provider JSON. `raw` holds the provider event only when
  `LlmDialect.Config.capture_raw` is `:all`.
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
          | %LlmDialect.StreamDelta.Text{text: String.t()}
          | %LlmDialect.StreamDelta.ToolCall{
              id: String.t() | nil,
              name: String.t() | nil,
              arguments: String.t() | nil,
              index: index()
            }
          | %LlmDialect.StreamDelta.Thinking{
              text: String.t(),
              signature: String.t() | nil
            }
          | %LlmDialect.StreamDelta.MessageDelta{
              stop_reason: LlmDialect.stop_reason() | nil,
              usage: LlmDialect.Usage.t() | nil
            }
          | %LlmDialect.StreamDelta.Raw{data: map()}

  @type raw :: map() | nil

  @type t :: %__MODULE__{
          type: type(),
          index: index(),
          delta: delta(),
          raw: raw()
        }

  defstruct [:type, :index, :delta, :raw]
end
