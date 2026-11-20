defmodule LlmCall.Examples.Gemini do
  @moduledoc """
  Gemini's endpoint: the API key travels in a header, and both codecs live under
  `v1beta` with different paths.

  `GenerateContent` can return text and images from one request through
  `Request.modalities`; Imagen's `predict` is a separate media codec.
  """

  use LlmCall.Provider,
    base_url: "https://generativelanguage.googleapis.com",
    auth: {:header, "x-goog-api-key"},
    codecs: [
      chat: LlmCall.Dialect.Gemini.GenerateContent,
      images: LlmCall.Media.Dialect.Gemini.Predict
    ],
    timeout: 120_000
end
