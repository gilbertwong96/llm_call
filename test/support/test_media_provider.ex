defmodule LlmCall.TestMediaProvider do
  @moduledoc "Provider definition used by the media client tests."

  use LlmCall.Provider,
    base_url: "https://media.example.test",
    auth: :none,
    codecs: [
      images: LlmCall.TestCodec.FakeMedia,
      async: LlmCall.TestCodec.AsyncMedia
    ]
end
