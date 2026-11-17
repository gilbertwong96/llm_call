# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First release, not yet published to Hex.

### Added

- Canonical wire IR: `Request`, `Message`, `Content`, `ToolSpec`, `ToolCall`,
  `ToolResult`, `Reasoning`, `Response`, `Usage`, `Error`, `Capabilities`,
  `Config`, `EncodedRequest`.
- `LlmDialect.Codec` behaviour and the public dispatch API, with typed errors for
  every unsupported field.
- Reference adapters: OpenAI Chat Completions, Anthropic Messages, Gemini
  GenerateContent.
- Adapter authoring macros: `LlmDialect.Protocol.Adapter` injects the behaviour,
  aliases, and `encode_request/2`; `LlmDialect.Media.Adapter` additionally
  injects the shared media validation pipeline. Shared rules live in
  `LlmDialect.Protocol.Helpers`.
- `provider_options` is validated, not just merged: a codec reserves the wire
  keys it derives from canonical fields, rejects a namespace it does not read,
  and refuses a `Config` default that would override an explicit request.
- Streaming primitives (`StreamEvent`, `StreamDelta`, `StreamState`) and the pure
  `StreamAssembler`.
- Media IR: `LlmDialect.Media.{Request,Response,Capabilities,Codec}`,
  `LlmDialect.Operation`, and the `encode_media/3` … `decode_operation/3` API for
  synchronous and long-running generation.
- Vendored media adapters: OpenAI Images, Gemini Imagen `predict`, Seedance
  (BytePlus ModelArk), MiniMax Hailuo.
- Conformance suites published from `lib/`: `LlmDialect.Codec.Conformance` and
  `LlmDialect.MediaConformance`, covering response/error decoding, stream order,
  tool-call assembly, `capture_raw`, and capability↔validation consistency.
- Documentation: `docs/design.md` (canonical spec), `CONTRIBUTING.md` (adapter
  bar), and the dated decision records under `docs/superpowers/specs/`.
