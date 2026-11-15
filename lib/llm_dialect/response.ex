defmodule LlmDialect.Response do
  @moduledoc """
  A provider-neutral completion response.

  `content` is a list of content parts, never provider-specific choices or
  output items. `raw` is a provider snapshot, retained only when
  `LlmDialect.Config.capture_raw` asks for it, and is never a second response
  model.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          model: String.t() | nil,
          content: [LlmDialect.Content.part()],
          stop_reason: LlmDialect.stop_reason(),
          usage: LlmDialect.Usage.t() | nil,
          raw: map() | nil
        }

  defstruct id: nil, model: nil, content: [], stop_reason: :unknown, usage: nil, raw: nil

  @doc "All text parts joined in order."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) do
    content
    |> Enum.flat_map(fn
      %LlmDialect.Content.Text{text: text} -> [text]
      _part -> []
    end)
    |> Enum.join()
  end

  @doc "The tool calls in this response, in order."
  @spec tool_calls(t()) :: [LlmDialect.ToolCall.t()]
  def tool_calls(%__MODULE__{content: content}) do
    Enum.filter(content, &is_struct(&1, LlmDialect.ToolCall))
  end
end
