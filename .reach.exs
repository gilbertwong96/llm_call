[
  layers: [
    helpers: "LlmCall.Dialect.Helpers",
    chat: [
      "LlmCall.Dialect.Adapter",
      "LlmCall.Dialect.OpenAI.*",
      "LlmCall.Dialect.Anthropic.*",
      "LlmCall.Dialect.Gemini.*"
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
