defmodule LlmCall.Examples.Anthropic do
  @moduledoc """
  Anthropic's endpoint: `x-api-key` auth and a required `max_tokens`.

  `provider_options.anthropic` reaches native knobs; `Reasoning.provider_options`
  reaches the `thinking` object without replacing its canonical fields.
  """

  use LlmCall.Provider,
    base_url: "https://api.anthropic.com",
    auth: :x_api_key,
    codecs: [chat: LlmCall.Dialect.Anthropic.Messages],
    timeout: 120_000
end
