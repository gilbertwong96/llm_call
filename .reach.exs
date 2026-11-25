[
  layers: [
    helpers: "LlmCall.Dialect.Helpers",
    chat: [
      "LlmCall.Dialect.Adapter",
      "LlmCall.Dialect.OpenAI.*",
      "LlmCall.Dialect.Anthropic.*",
      "LlmCall.Dialect.Gemini.*",
      "LlmCall.Dialect.Bedrock.*"
    ],
    media: "LlmCall.Media.*"
  ],
  deps: [
    forbidden: [
      {:chat, :media},
      {:media, :chat}
    ]
  ]
]
