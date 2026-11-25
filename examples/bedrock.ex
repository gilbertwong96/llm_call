defmodule LlmCall.Examples.Bedrock do
  @moduledoc """
  Bedrock's endpoint: `Converse`, on a signed request.

  `auth: {:sigv4, service: ..., region: ...}` signs every request with the caller's
  credentials, so the client takes `credentials:` — a map, or a 0-arity function
  that returns one — and an optional `region:` that overrides the declaration's.

  Text and tool use are carried. Images and documents need a later capability
  model: Converse takes them inline or from S3, never from a URL.
  """

  use LlmCall.Provider,
    base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
    auth: {:sigv4, service: "bedrock", region: "us-east-1"},
    codecs: [chat: LlmCall.Dialect.Bedrock.Converse],
    timeout: 120_000
end
