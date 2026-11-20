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
  `%LlmCall.Client{}`. HTTP is Finch; JSON is the `LlmCall.JSON` facade over
  Elixir's built-in `JSON`, selected at compile time with `json_library:`;
  Torque, Jason and Poison work directly. Calls accept `headers:` merged after the client
  headers and before the codec's protocol headers.
- A provider-level `query:` (or a `query:` client option) adds URL parameters to
  every request, for vendors that key on one — MiniMax's `GroupId`, Azure
  OpenAI's `api-version`. A codec's own parameter wins on the same key, and the
  Responses WebSocket handshake inherits the same parameters.
- `LlmCall.Error.retry_after_ms` carries the parsed `Retry-After` hint; retry
  policy stays outside the core. `LlmCall.Error.reason` carries the structured
  transport reason (`:econnrefused`, `:timeout`, `:unknown_pool`, ...), so callers
  match on it instead of parsing the message.
- `LlmCall.HTTP.build_url/3` joins a base URL, a request path and an encoded query
  on the `URI` struct, keeping the base path. The client and the Responses
  WebSocket handshake both use it, so a caller that owns a transport joins its
  URLs the way the library does.
- `LlmCall.Codec.Conformance.assert_replays/3` pins which decoded content parts a
  codec accepts back in an assistant message, the contract an agent loop depends
  on; `docs/design.md` §8.2 carries the table.
- `config :llm_call, capture_raw: ...` sets the compile-time capture default,
  symmetric with `json_library:`; `LlmCall.Config.new(capture_raw: ...)` still
  overrides it per client.
- Codecs validate the types of known native `provider_options` keys
  (`access_programs`, `logprobs`, `metadata`, `safetySettings`, ...); unknown
  native keys still pass through.
- WebSocket transport: the `LlmCall.WS` behaviour and `LlmCall.WS.Mint`, with
  the upgrade, text/binary frames, ping handling and peer close. Mint's HTTP
  proxy options are forwarded (`ws://` forward proxy, `wss://` CONNECT).
- Responses WebSocket connection: one socket multiplexed by `stream_id`,
  `Connection.response_id/2` for `previous_response_id`,
  `response.create`/`response.steer`/`response.cancel`, per-lane event decoding,
  and reconnect before the 60-minute limit. Reconnect failures keep the connection
  process alive with exponential backoff; while disconnected, creates return a
  `:transport` error. In-flight responses are reported as interrupted, not
  silently resumed. No realtime audio session.
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
- Reference adapters: OpenAI Chat Completions, OpenAI Responses, Anthropic
  Messages, Gemini GenerateContent.
- Adapter authoring macros: `LlmCall.Dialect.Adapter` injects the behaviour,
  aliases, and `encode_request/2`; `LlmCall.Media.Dialect.Adapter` additionally
  injects the shared media validation pipeline. Shared rules live in
  `LlmCall.Dialect.Helpers`.
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
  `LlmCall.Media.Conformance`, covering response/error decoding, stream order,
  the streaming signal on an encoded request, tool-call assembly, `capture_raw`,
  and capability↔validation consistency.
- Documentation: `docs/design.md` (canonical spec) and `CONTRIBUTING.md` (adapter
  bar).

### Fixed

- `http_opts: [receive_timeout: ...]` was validated and then dropped: the client
  always forwards the request's own timeout. It is now an `ArgumentError` that
  points at `timeout:`, and any key the client would drop is rejected the same
  way.
- A CRLF split across two body chunks ended an SSE event early, which broke the
  documented newline join for multi-line `data:` fields.
- `ToolCall.arguments_error` carried the raw arguments in one path and a decoder
  message in another. `raw_arguments` is now the only place the payload lives:
  `{:invalid_json, reason}` always carries a message, and a missing decoder is
  `:no_json_decoder`.
- `response.steer` and `response.cancel` carried `stream_id`, which the provider
  does not route them by: a steer carries `previous_response_id` and a cancel
  carries `response_id`. Steering a lane that has not received `response.created`
  is a `:validation` error instead of an untenanted event.
- A Responses connection whose server does not echo `stream_id` (the endpoint does
  for named lanes) no longer accepts a second concurrent lane once an event has
  proven the echo is missing, because that lane's events could not be routed and
  the connection would drop every in-flight response with an opaque
  `unroutable_event`. Back-to-back creates before the first event stay allowed.
- `LlmCall.Config` merged provider-option namespaces one level deep, so a nested
  `default_provider_options` key was dropped as soon as the request set a sibling
  key inside the same object — for six of the eight codecs; Gemini already
  deep-merged. The merge is now recursive for every codec.
- `Error.raw` carried the provider error envelope whatever `capture_raw` said,
  while `Response.raw`, `StreamEvent.raw` and `Operation.raw` honoured it. It now
  follows the same policy, so `:none` keeps no provider payload at all. The
  conformance suites check it for completion and media codecs.
- `LlmCall.Media.Dialect.Gemini.Predict` accepted a non-string
  `params.negative_prompt` and put it on the wire; it is now a `:validation`
  error like its sibling knobs.
- A query string in `base_url` (`https://…/openai?api-version=1`) was glued in
  front of the codec path over HTTP, producing `/openai?api-version=1/v1/…` on the
  wire; the WebSocket handshake already merged it. It is now folded into the
  client's `query` at build time, with an explicit `query:` winning.
