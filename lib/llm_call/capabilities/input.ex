defmodule LlmCall.Capabilities.Input do
  @moduledoc """
  Where a codec can get the bytes for an image or a file part.

  A single boolean cannot answer "can I send this part", because the canonical source
  has three kinds and the protocols disagree about them: OpenAI Responses takes a
  provider `file_id`, Anthropic takes one for a document but not for an image, Gemini
  takes neither, and a URL is not the same thing as a file the provider already has.
  Declaring `true` for all of them made the declaration wrong in one direction or the
  other, and `false` refused parts the codec could encode.

  So a capability names the kinds it accepts, one boolean each:

  | Kind | Canonical source | Who resolves it |
  | --- | --- | --- |
  | `:inline` | `{:base64, data}` | the bytes travel in the request |
  | `:url` | `{:url, url}`, or a bare string | the provider fetches it |
  | `:file` | `{:file_id, id}` | the provider resolves a reference it already holds |

  The default accepts nothing, which is what `false` meant before. `accepts?/2`
  answers the question for a concrete part, and `kinds/1` lists what a declaration
  allows.

      %LlmCall.Capabilities{
        image_input: %LlmCall.Capabilities.Input{inline: true, url: true}
      }
  """

  @typedoc "One way of naming the bytes of a part."
  @type kind :: :inline | :url | :file

  @type t :: %__MODULE__{inline: boolean(), url: boolean(), file: boolean()}

  defstruct inline: false, url: false, file: false

  @kinds [:inline, :url, :file]

  @doc "The kinds a declaration accepts, in canonical order."
  @spec kinds(t()) :: [kind()]
  def kinds(%__MODULE__{} = input), do: Enum.filter(@kinds, &Map.fetch!(input, &1))

  @doc "Whether a canonical source is one this declaration accepts."
  @spec accepts?(t(), LlmCall.Content.source()) :: boolean()
  def accepts?(%__MODULE__{} = input, source), do: Map.fetch!(input, kind(source))

  @doc """
  The kind a canonical source belongs to.

  A bare string is a URL: it is the shorthand the HTTP codecs already read as one.
  """
  @spec kind(LlmCall.Content.source()) :: kind()
  def kind({:base64, _data}), do: :inline
  def kind({:url, _url}), do: :url
  def kind({:file_id, _id}), do: :file
  def kind(url) when is_binary(url), do: :url
end
