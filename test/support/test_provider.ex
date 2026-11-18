defmodule LlmCall.TestProvider do
  @moduledoc "Provider definition used by the client tests."

  use LlmCall.Provider,
    base_url: "https://api.example.test/v1",
    auth: :bearer,
    codecs: [chat: LlmCall.TestCodec.Fake]
end
