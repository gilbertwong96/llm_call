defmodule LlmCall.Examples.OpenAI do
  @moduledoc """
  OpenAI's endpoint: a bearer key, one base URL, three codecs.

  Chat, Responses and image generation share the host and the auth, but not the
  request shape, so all three are declared here and selected per call.
  """

  use LlmCall.Provider,
    base_url: "https://api.openai.com",
    auth: :bearer,
    codecs: [
      chat: LlmCall.Protocol.OpenAI.Chat,
      responses: LlmCall.Protocol.OpenAI.Responses,
      images: LlmCall.Media.Protocol.OpenAI.Images
    ],
    timeout: 120_000
end
