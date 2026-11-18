defmodule LlmCall.Examples.DeepSeek do
  @moduledoc """
  An OpenAI-compatible provider: the OpenAI Chat codec, another base URL.

  This is the escape hatch the design describes — a compatible API reuses the
  codec and changes the endpoint, auth shape and `provider_options` namespace.

  Hosted tools (for example DeepSeek's web search) go through the builtin tool
  envelope when the codec forwards them:

      tools = [%LlmCall.ToolSpec{kind: :builtin, name: "web_search"}]
  """

  use LlmCall.Provider,
    base_url: "https://api.deepseek.com/v1",
    auth: :bearer,
    codecs: [chat: LlmCall.Protocol.OpenAI.Chat]
end
