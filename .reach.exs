[
  layers: [
    helpers: "LlmDialect.Protocol.Helpers",
    chat: [
      "LlmDialect.Protocol.Adapter",
      "LlmDialect.Protocol.OpenAI.*",
      "LlmDialect.Protocol.Anthropic.*",
      "LlmDialect.Protocol.Gemini.*"
    ],
    media: "LlmDialect.Media.*"
  ],
  deps: [
    forbidden: [
      {:chat, :media},
      {:media, :chat}
    ]
  ]
]
