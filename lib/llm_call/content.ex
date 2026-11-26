defmodule LlmCall.Content.Text do
  @moduledoc "A text block."

  @type t :: %__MODULE__{text: String.t()}

  defstruct [:text]
end

defmodule LlmCall.Content.Image do
  @moduledoc "An image block. `source` is a URL, base64 data, or a provider file id."

  @type t :: %__MODULE__{
          source: LlmCall.Content.source(),
          media_type: String.t() | nil
        }

  defstruct [:source, :media_type]
end

defmodule LlmCall.Content.File do
  @moduledoc "A document or file block."

  @type t :: %__MODULE__{
          source: LlmCall.Content.source(),
          media_type: String.t() | nil,
          filename: String.t() | nil
        }

  defstruct [:source, :media_type, :filename]
end

defmodule LlmCall.Content.Thinking do
  @moduledoc """
  A reasoning block.

  `signature` carries whatever the provider requires to replay the block in a
  later request. Anthropic returns one on every thinking block and rejects the block
  when it comes back without it; Gemini returns one on the thought parts that precede
  a function call and accepts an unsigned thought otherwise. It is a provider-issued
  token the API validates, not something to build or edit: put the decoded struct
  back into an assistant message as it is.

  A streamed block arrives as more than one event; see
  `LlmCall.StreamDelta.Thinking`.
  """

  @type t :: %__MODULE__{text: String.t(), signature: String.t() | nil}

  defstruct [:text, :signature]
end

defmodule LlmCall.Content.Raw do
  @moduledoc """
  A provider block the codec does not understand.

  `type` is the provider's own discriminator and `data` is the provider's payload.
  A codec that can render the block back emits `data` as-is, so a block decoded from
  a response already carries its discriminator and `type` stays a caller-side
  label; one built by hand must put the discriminator inside `data` too. This is an
  escape hatch, not a substitute for a canonical type.
  """

  @type t :: %__MODULE__{type: String.t() | nil, data: map()}

  defstruct [:type, :data]
end

defmodule LlmCall.Content.Video do
  @moduledoc "A video block, used for references and generated assets."

  @type t :: %__MODULE__{
          source: LlmCall.Content.source(),
          media_type: String.t() | nil
        }

  defstruct [:source, :media_type]
end

defmodule LlmCall.Content do
  @moduledoc """
  Canonical content parts.

  A content part is one item of a message or response body. Tool calls and tool
  results are parts, not a separate message role, because providers disagree on
  how they are carried.
  """

  @type source ::
          String.t()
          | {:url, String.t()}
          | {:base64, String.t()}
          | {:file_id, String.t()}
          | {:uri, String.t()}

  @type part ::
          %LlmCall.Content.Text{text: String.t()}
          | %LlmCall.Content.Image{source: source(), media_type: String.t() | nil}
          | %LlmCall.Content.File{
              source: source(),
              media_type: String.t() | nil,
              filename: String.t() | nil
            }
          | %LlmCall.Content.Video{source: source(), media_type: String.t() | nil}
          | %LlmCall.ToolCall{}
          | %LlmCall.ToolResult{}
          | %LlmCall.Content.Thinking{text: String.t(), signature: String.t() | nil}
          | %LlmCall.Content.Raw{type: String.t() | nil, data: map()}
end
