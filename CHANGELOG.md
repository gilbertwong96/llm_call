# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- `auth: {:sigv4, service: ..., region: ...}` signs every request with AWS
  Signature Version 4. Credentials are a client option — `credentials:` takes a
  map or a 0-arity function that returns one — and `region:` overrides the
  declared region per client.
- `LlmCall.Dialect.Bedrock.Converse` encodes and decodes Bedrock's `Converse` API:
  text, tool use and tool results. Images and documents are refused until the
  capability model can say "inline only"; streaming waits for its stream callbacks,
  which now have their framing (`LlmCall.EventStream`).
- `provider_options.bedrock` is merged into the top level of the Converse request,
  the rule the other codecs follow, so `guardrailConfig` and Bedrock's other
  top-level fields are reachable. The canonical envelope keys are reserved and a
  collision is a `:validation` error. `additionalModelRequestFields` is written
  nested, as it appears on the wire.
- `LlmCall.EventStream` decodes `application/vnd.amazon.eventstream`, the framing
  `ConverseStream` answers with: length-prefixed frames, typed headers, CRC-32 over
  both the prelude and the message, and a truncation check at end of body. The test
  frames come from `@smithy/eventstream-codec`, an implementation this decoder shares
  no code with.
- Telemetry: `[:llm_call, :request, ...]` and `[:llm_call, :stream, ...]` events
  carry the operation, provider, codec and model; `:stop` adds the outcome, the
  status, and the token counts as measurements, and a stream reports `:first_event`
  (first event) and `:first_text` (first visible token) separately. No handler is
  attached, so the cost is zero until a host subscribes. See `LlmCall.Telemetry`.

## 0.2.0 - 2026-11-24

### Breaking changes

- A stream that ends without its protocol terminator is now an error. OpenAI Chat
  and OpenAI Responses used to synthesize a `:message_stop`, and Anthropic ended
  silently, so a body cut short by a proxy limit or a provider bug looked like a
  completed stream. `finish_stream/2` on those three codecs returns
  `{:error, %LlmCall.Error{kind: :invalid_response}}`, which `LlmCall.Stream`
  raises as `LlmCall.HTTP.Error`. Gemini keeps flushing, because its protocol has
  no terminator.
- Header values must be printable ASCII with no leading or trailing whitespace.
  Values outside that used to reach Mint, which rejects them with a message that
  embedded the value — including an `api_key`.
- `:pool_strategy` validates against Finch's own contract: `nil`, a module
  exporting `select/2`, `{module, state}`, a 1-arity function, or
  `{2-arity function, state}`. It previously accepted `:random`, `:ordered` and
  integers, none of which Finch dispatches on, so every accepted value raised
  inside Finch.

### Added

- `Request.tools` accepts a [`tool_call`](https://hex.pm/packages/tool_call)
  module, or `{module, opts}` with `strict: boolean()`. A module contributes one
  `%LlmCall.ToolSpec{}` per declared tool, in declaration order; a
  `%LlmCall.ToolSpec{}` entry still passes through unchanged, and the three forms
  mix freely in one list. `strict: true` asks for OpenAI's strict schema, while
  `strict: false` is treated as absent rather than sent as a flag; a codec with
  no per-tool flag rejects `true`.
- `LlmCall.Tools.expand/2` turns tool entries into specs for a codec, and
  `LlmCall.Tools.normalize_request/2` applies it to a whole request. Every entry
  point that forwards a request to a codec normalizes first: `complete/3`,
  `stream/3`, `encode/3`, `validate_request/3`, `init_stream/3`, and
  `Responses.Connection.create/3`. `capabilities/3` reads no tools.
  `LlmCall.Codec.Conformance` calls the codec callbacks directly, so a request
  handed to one of its assertions must already carry `%LlmCall.ToolSpec{}`
  entries.
- `LlmCall.StreamAssembler.new/1` takes `max_argument_bytes`, 8 MiB by default.
  Fragments accumulate across events, which the SSE frame cap cannot bound; past
  the cap a call finalises with `{:too_large, bytes}`, a new variant of
  `LlmCall.ToolCall.arguments_error`, and `raw_arguments` keeps the prefix that
  fit.
- New dependency `tool_call ~> 0.4`, which has no runtime dependencies of its own.

### Changed

- The tool schema projection is chosen from `codec.info().protocol`:
  `:openai_chat` and `:openai_responses` take the schema `ToolCall.emit/3`
  renders for OpenAI, `:gemini_generate_content` the one it renders for Gemini,
  and any other protocol the neutral schema `ToolCall.describe/2` returns. Gemini
  therefore no longer needs a manual `to_gemini/2` step.
- `LlmCall.HTTP.request/2` and `stream/4` no longer let a transport failure escape.
  A Finch exception or exit is reported as `reason: :exception`, and a failure that
  never produced a response is classified by its reason: the connection-level
  causes a new attempt can fix are `retryable?: true`, where every one of them used
  to be `false`.
- Tool-argument fragments are kept as iodata and joined once instead of appended
  per fragment, which was quadratic for large arguments.
- `ToolResult.is_error` is dropped on OpenAI Chat and Responses, and a tool call
  whose arguments did not decode is sent as `%{}` on Anthropic and Gemini. Those
  protocols have no field for either, so put the failure in the content text and
  expect to repair a bad arguments fragment without the model seeing it.

### Fixed

- A malformed tool entry, a module that does not `use ToolCall`, and a schema the
  selected protocol cannot render are `:validation` errors from
  `Tools.expand/2`, naming the codec that refused, rather than raises.
- `poll/3` returns a typed validation error when an operation's `next` is neither
  `nil` nor an `%EncodedRequest{}`, instead of raising `CaseClauseError`.
- Gemini streaming no longer reports `stop_reason: :tool_calls` when no call was
  emitted, an unmappable part arrives as `StreamDelta.Raw` instead of nothing, and
  a thought part carrying only a signature arrives as `StreamDelta.Thinking`.
- The OpenAI Responses codec rejects a text, reasoning or tool-argument delta whose
  payload is not a string, rather than emitting a delta that breaks the documented
  fold.
- The Anthropic codec refuses image and document blocks in an assistant turn, and
  applies the non-empty text rule to text blocks nested in a `tool_result`.
- A non-2xx response body is capped at 64 KiB, and the error says the body was
  truncated rather than reporting invalid JSON. A status and `Retry-After` captured
  before the body failed are kept instead of being discarded with the accumulator.
- An error message copied from a provider is required to be a string, so a gateway
  that answers `{"error": {"message": {…}}}` cannot break `%LlmCall.Error{}`.
- Gemini's Imagen codec reports an empty `predictions` array as a `:provider` error
  — everything was filtered — instead of `:invalid_response`.
- A failed MiniMax or Seedance job keeps the codec's own `retryable?` verdict, and
  Seedance normalizes a numeric submit id instead of refusing it.

### Security

- `inspect` on `%LlmCall.Client{}`, `%LlmCall.HTTP.Request{}` and `%LlmCall.Stream{}`
  leaves out the parts that carry the resolved credential, so logging one no longer
  prints the key.

### Compatibility

- The supported floor moves from OTP 27 to 27.1, which `tool_call` requires for
  `json:format/1`.

## 0.1.1 - 2026-11-23

### Breaking changes

- `Helpers.validate_params/3` is removed. It validated the key names of `params`
  but not their values, so `temperature: "hot"` and `max_tokens: -5` passed, and
  its shorter name made it the obvious choice over the spec-driven validator for
  an out-of-tree adapter. Use `Helpers.validate_params_with_spec/4` with a
  `@param_spec`; `Helpers.validate_param_keys/3` and
  `Helpers.validate_param_values/4` remain as the two halves it composes.

### Added

- `LlmCall.SSE` keeps the server's `retry:` hint on the state as `retry_ms`
  instead of dropping it, so a caller that owns reconnection policy can read it.
  The library still never reconnects a stream on its own.

### Changed

- Gemini tool `parameters` and `responseSchema` now reject schemas its OpenAPI
  subset cannot express: a lowercase `type`, `additionalProperties`,
  `$ref`/`$defs`, `prefixItems`, `oneOf` or `const` is a `:validation` error
  instead of a provider request. `ToolSpec.parameters` is documented as
  already-projected wire data.

- `Error.retryable?` is now the union of the codec's verdict and the HTTP status
  (`LlmCall.Error.retryable_status?/1`: `408`, `425`, `429`, `500`, `502`, `503`,
  `504`). Before, a `429` whose body named a code the codec did not list reported
  `retryable?: false`, while the same `429` with an unparseable body reported
  `true` — better evidence gave the worse answer, and a provider that introduced a
  new rate-limit code silently stopped retries.
- `LlmCall.Codec.Conformance.assert_capability_consistency/3` no longer reports a
  reasoning budget as rejected by a codec that correctly requires it to be below
  `params.max_tokens`. The sample now tracks the request, so the suite can be run
  against Anthropic, which it previously could not.
- A `params` value is now validated against the protocol, not only its key: a
  `temperature` outside the documented range, a non-numeric `top_p`, a
  `max_tokens` below 1, a `seed` that is not an integer, or a `stop` that is
  empty, over the limit, or not a string, is a `:validation` error instead of a
  value sent to the provider. The bounds differ per protocol (`temperature` is
  `0..2` on OpenAI and Gemini, `0..1` on Anthropic) and are recorded in
  `docs/design.md` §8.11.
- A content part now validates its payload. A `{:base64, data}` source must be
  base64, padding optional; a `media_type` must be a `type/subtype` such as
  `image/png` rather than free text. Both were previously sent verbatim.

### Fixed

- A tool call the decoder could not parse could not be replayed. The decoder keeps
  the malformed `raw_arguments` and sets `arguments_error`, but every codec's
  validator demanded a decodable object, so an assistant turn carrying that call
  was rejected. A model does not always generate valid JSON, and the repair is to
  send that turn back with a tool result saying so — the round trip is now open,
  while a hand-written fragment with no `arguments_error` is still rejected.
- The Anthropic codec accepted an empty or whitespace-only text block, and a
  whitespace-only `system` prompt, all of which the Messages API rejects
  (`messages: text content blocks must be non-empty`, `... must contain
  non-whitespace text`). A response can carry an empty text block, so replaying
  that history produced a request the provider refuses; it is now a `:validation`
  error. OpenAI and Gemini accept the same shape, so the rule stays in this codec.
- `tool_choice` was not cross-referenced against `tools`, so `{:tool, "typo"}`
  produced a request naming a tool the request never declares. OpenAI and
  Anthropic reject that with a 400 (Anthropic: "tool_choice not in tools"), and
  Gemini requires `allowedFunctionNames` to match a `FunctionDeclaration.name`.
  It is now a `:validation` error naming the undeclared tool; a builtin tool's
  `name` counts as declared. Gemini's `{:allowed, []}` is rejected as well, since
  `mode: ANY` derived from it would require a call while allowing none.
- The default WebSocket transport raised `FunctionClauseError` for a URL that is
  not a string, because `URI.parse/1` only accepts a binary. The `LlmCall.WS`
  behaviour promises `{:ok, conn()} | {:error, error()}`, so a non-string URL is
  now `{:error, {:invalid_url, url}}` like any other unusable URL.
- The Gemini codec accepted `allOf` and `not` in tool `parameters` and in
  `responseSchema`, though its OpenAPI subset cannot express either; both are now
  `:validation` errors like `oneOf` and `const`.
- Two tool specs sharing a `name` are now a `:validation` error. The second entry
  was unreachable, and a provider either rejects the request or picks one.
- A provider error whose body is not JSON (a gateway's HTML or plain text) now
  keeps an excerpt in `Error.message` instead of reporting only
  "unrecognized error payload". `Error.raw` still carries maps only, so a
  non-map body is visible in the message rather than in `raw`.
- A function tool name is now checked against the target protocol's published
  class: 64 characters of `[a-zA-Z0-9_-]` on OpenAI Chat, 128 on Anthropic, and
  `[a-zA-Z_][a-zA-Z0-9_.:-]*` up to 128 on Gemini. OpenAI Responses publishes no
  constraint and is left unchecked. A name outside the class was previously sent
  and rejected by the provider.
- `LlmCall.Application.default_children/1` raised an opaque `ArgumentError` for a
  pool name that is not an atom; it now says the name must be an atom.
- `LlmCall.HTTP.build_url/3` no longer renders a trailing `?` when the query is an
  empty string.
- An SSE stream whose pending event grew without bound now raises
  `LlmCall.SSE.Error` at 1 MiB instead of consuming memory until the process dies.
  `LlmCall.Stream` reports it as an `:invalid_response` `LlmCall.HTTP.Error`.
- A non-`2xx` whose body is not the provider's error envelope (a gateway's HTML,
  an empty body) reported `retryable?: false` whatever the status was, so a real
  `429` or `503` answered by a CDN told the caller not to retry. The hint is now
  derived from the status in that case — `408`, `425`, `429`, `500`, `502`, `503`
  and `504` are retryable. When the body does decode, the codec's own verdict
  still stands.
- Every dispatch and top-level call raised `FunctionClauseError` for an argument
  that was not the expected struct, though each `@spec` promises
  `{:ok, _} | {:error, %LlmCall.Error{}}`. `encode/3`, `validate_request/3`,
  `capabilities/3`, `init_stream/3`, `decode_stream_event/4`, `finish_stream/3`,
  `encode_media/3`, `validate_media/3`, `media_capabilities/3`, `complete/3`,
  `stream/3`, `generate/3`, `poll/3`, `execute/2` and `fetch/2` now return a
  `:validation` error naming the expected type. A top-level call names whichever
  of its two struct arguments did not match.
- A stream whose payload is not JSON dropped both the payload and the decoder's
  reason, leaving only "stream payload is not JSON". A truncated frame, a gateway's
  plain-text body and a malformed chunk all read the same, and the stream could not
  be diagnosed from the error. The message now quotes the payload and carries the
  decoder's reason. The same applies to a request or response body that fails to
  encode or decode on the non-streaming path.
- The Anthropic codec put a `tool_result` block wherever the caller placed it,
  including after text, which the Messages API rejects: results must come first in
  the message that answers a call. That ordering is now a `:validation` error.
- A `%LlmCall.ToolResult{}` that answers no tool call in the immediately preceding
  message is now a `:validation` error naming the id and index, instead of a
  request both OpenAI and Anthropic reject with a 400. A history with an
  unanswered tool call is still accepted, because a truncated turn is the
  caller's decision.
- `Capabilities.prompt_cache` and `Capabilities.stateful` claimed a request
  capability they never had: the canonical IR has no field to place a cache
  breakpoint or continue a response. They are now documented as reporting
  capabilities — cache accounting in `Usage`, server-side continuation through
  `provider_options` — which is what `true` always meant.

## 0.1.0 - 2026-11-20

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
  on; `docs/design.md` §8.3 carries the replay table.
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
- The Anthropic codec emitted server tools as `{"type": …}` alone, but the API
  requires the callable `name` as well (`web_search` next to
  `web_search_20250305`). It is now derived from the type's date suffix and can be
  overridden through `provider_options.anthropic`.
- The Anthropic codec accepted `thinking.budget_tokens` from 1 upward; the API
  requires at least 1024 and less than `max_tokens`, so both bounds are validation
  errors now.
- `Usage.total_tokens` for Anthropic counted only `input_tokens + output_tokens`,
  while the API defines `input_tokens` as the tokens *after* the last cache
  breakpoint: cache creation and cache reads were missing from the total.
- The Anthropic `anthropic-version` header was pinned to `2023-06-01`; it now sends
  the version the provider's own SDK sends, `2026-10-21`. A codec header wins over a
  client header, so the pin was not overridable.
- The OpenAI Chat and Responses codecs rejected `reasoning effort: :xhigh` and
  `:max`, which `ReasoningEffort` accepts, and their `Usage.cache_write_tokens` was
  always `nil` although both usage breakdowns report it
  (`prompt_tokens_details.cache_write_tokens`, `input_tokens_details.cache_write_tokens`).
- The OpenAI Responses codec replayed an assistant turn with `output_text` content
  parts, which are not valid in an input content list: the documented `input` shape
  allows `input_text`, `input_image`, and `input_file`, and an assistant turn is
  either an easy-input message with those parts or the original output item with its
  id. It now emits `input_text`.
- The Gemini codec mapped most `finishReason` values to `:unknown`. The documented
  set now maps as it reads: `CONTINUATION` (a resumable token-limit stop) to
  `:max_tokens`, the content-policy family (safety, recitation, language, blocklist,
  prohibited content, SPII, the image variants, escalation) to `:content_filter`, and
  the failed-generation reasons (`MALFORMED_FUNCTION_CALL`, `UNEXPECTED_TOOL_CALL`,
  `TOO_MANY_TOOL_CALLS`, `MISSING_THOUGHT_SIGNATURE`, `MALFORMED_RESPONSE`,
  `NO_IMAGE`, `IMAGE_OTHER`, `PUP_LIMITED_DISABLED`) to `:error`.
- The OpenAI Images codec sent `response_format: "b64_json"` to `dall-e-*` models.
  That parameter is legacy for the retired DALL·E models and is unsupported by the
  GPT image models, which always return base64; it is now only sent when a caller
  sets it through `provider_options.openai`.
- The Seedance video codec dropped the task's token usage; a finished task reports
  `completion_tokens` and `total_tokens`, which now land on
  `LlmCall.Media.Response.usage`.
