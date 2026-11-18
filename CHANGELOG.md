# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First release, not yet published to Hex. The project is renamed from `llm_dialect`
back to `llm_call` because it now ships the client that name promised.

### Added

- One-call client: `LlmCall.complete/3`, `stream/3`, `generate/3`, `poll/3`,
  `execute/2`, `fetch/2`, with `LlmCall.Provider` (`use LlmCall.Provider`) and
  `%LlmCall.Client{}`. The HTTP and JSON layers are behaviours
  (`LlmCall.HTTP`, `LlmCall.JSON`) resolved call option →
  provider → `config :llm_call, ...` → default.
- Streaming in the library: `LlmCall.SSE` framing, `LlmCall.Stream` as a lazy
  `Enumerable`, `stream/3`'s `on_event:` observer, and `LlmCall.HTTP.Error` for
  mid-stream failures.
- Provider-hosted tools: `ToolSpec{kind: :builtin}` forwarded verbatim and
  `Capabilities.builtin_tools`.
- Canonical wire IR: `Request`, `Message`, `Content`, `ToolSpec`, `ToolCall`,
  `ToolResult`, `Reasoning`, `Response`, `Usage`, `Error`, `Capabilities`,
  `Config`, `EncodedRequest`.
- `LlmCall.Codec` behaviour and the public dispatch API, with typed errors for
  every unsupported field.
- Reference adapters: OpenAI Chat Completions, Anthropic Messages, Gemini
  GenerateContent.
- Adapter authoring macros: `LlmCall.Protocol.Adapter` injects the behaviour,
  aliases, and `encode_request/2`; `LlmCall.Media.Adapter` additionally
  injects the shared media validation pipeline. Shared rules live in
  `LlmCall.Protocol.Helpers`.
- `provider_options` is validated, not just merged: a codec reserves the wire
  keys it derives from canonical fields, rejects a namespace it does not read,
  and refuses a `Config` default that would override an explicit request.
- Streaming primitives (`StreamEvent`, `StreamDelta`, `StreamState`) and the pure
  `StreamAssembler`.
- Media IR: `LlmCall.Media.{Request,Response,Capabilities,Codec}`,
  `LlmCall.Operation`, and the `encode_media/3` … `decode_operation/3` API for
  synchronous and long-running generation.
- Vendored media adapters: OpenAI Images, Gemini Imagen `predict`, Seedance
  (BytePlus ModelArk), MiniMax Hailuo.
- Conformance suites published from `lib/`: `LlmCall.Codec.Conformance` and
  `LlmCall.MediaConformance`, covering response/error decoding, stream order,
  the streaming signal on an encoded request, tool-call assembly, `capture_raw`,
  and capability↔validation consistency.
- Documentation: `docs/design.md` (canonical spec) and `CONTRIBUTING.md` (adapter
  bar).
