[
  layers: [
    helpers: "LlmCall.Protocol.Helpers",
    chat: [
      "LlmCall.Protocol.Adapter",
      "LlmCall.Protocol.OpenAI.*",
      "LlmCall.Protocol.Anthropic.*",
      "LlmCall.Protocol.Gemini.*"
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
