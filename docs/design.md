# LlmCall Design

Status: draft for implementation
Date: 2026-11-12
Project: `llm_call`
Module namespace: `LlmCall`

## 1. Summary

`LlmCall` is a **call-oriented SDK** for LLM APIs: a canonical wire IR, protocol
codecs, and a one-call client on Finch whose JSON layer is replaceable.

The library ships the canonical IR, the codec behaviours, the conformance
suites, four **reference adapters** — the dialect families the IR is written
against — and a set of **vendored media adapters**. Provider coverage is still
not a goal: the IR's value comes from the breadth of knowledge behind it, not
from the breadth of shipped code. A vendored adapter tracks its provider's API;
the IR it maps into is the stable surface.

`LlmCall.complete/3` turns a provider-neutral request into a round trip:
validate, encode, send, decode. It deliberately does **not** own model discovery,
authentication lookup, approvals, retries, or an agent loop.

The encode/decode functions remain public, so a caller that already owns a
transport can use the codecs without the client.

The core idea:

```text
canonical request
      |
      v
LlmCall.Client (provider + endpoint + defaults)
      |
      v
LlmCall.Codec.encode_request/2
      |
      v
encoded request  ----  LlmCall.HTTP (default Finch)  ---->  provider
      |
      v
provider response term   (LlmCall.JSON, default Elixir JSON)
      |
      v
LlmCall.Codec.decode_response/2
      |
      v
canonical response
```

This is intentionally a smaller layer than a complete LLM client. It can be
used by a higher-level client, an agent framework, or a custom application.

## 2. Position

### 2.1 What problem this solves

Providers do not agree on:

- request envelopes (`messages` versus `input`, `contents`, etc.)
- system prompt placement
- tool definitions and tool choice
- tool call and tool result representation
- content blocks and multi-modal inputs
- response envelopes (`choices`, output items, content blocks)
- streaming event shapes
- stop reasons, usage accounting, and errors
- state and continuation semantics

`LlmCall` provides one stable Elixir data model for these wire-level concepts.

### 2.2 What this is not

`LlmCall` is not:

- a provider gateway: it does not route by model name or keep a model catalog
- a model registry or pricing database
- a tokenizer or context-window planner
- a retry/rate-limit/circuit-breaker layer
- an authentication manager
- a tool executor
- an approval, timeout, or audit system
- an agent loop, memory, prompt-template, or chain framework
- a replacement for `ReqLLM` or LangChain
- a provider catalog, or a promise to support every provider. Beyond the
  reference and vendored adapters in this repository, an adapter is an
  application's own module or a third-party package (see §14)

Its HTTP execution is in the core on Finch; JSON encoding is behind
`LlmCall.JSON` (Elixir `JSON` by default). SSE framing (`LlmCall.SSE`) is a core
module, and WebSocket connections go through the `LlmCall.WS` behaviour with
`LlmCall.WS.Mint` as the implementation. HTTP and SSE are not replaceable seams;
WebSocket has a behaviour, but no config-level transport resolution.

### 2.3 Relationship to `tool_call`

`LlmCall` does not depend on the `tool_call` project.

The tool concepts in `LlmCall` are wire data only:

- `LlmCall.ToolSpec`: what the model may call
- `LlmCall.ToolCall`: what the model asked to call
- `LlmCall.ToolResult`: the result of a call, ready to send back to the model

The application maps between them; neither project depends on the other:

A `ToolCall.describe/2` entry becomes a `%LlmCall.ToolSpec{}` with its
`name`, `description` and `parameters`.

`ToolCall.describe/2` returns a provider-neutral `name`/`description`/`parameters`
per tool, and a decoded `%LlmCall.ToolCall{}` carries the name and arguments
`ToolCall.run/4` needs. `parameters` must already be in the selected codec's
dialect: the Gemini codec validates its OpenAPI subset and returns `:validation`
for constructs it cannot send.

### 2.4 Relationship to LangChain and ReqLLM

| Project          | Focus                                                                    |
|------------------|--------------------------------------------------------------------------|
| LangChain Elixir | Chains, conversation flow, tool execution, callbacks                     |
| ReqLLM           | Complete LLM client with provider transports, registry, streaming, tools |
| `LlmCall`     | Dialect codecs, canonical wire IR, one-call client                      |

`LlmCall` can be used underneath those systems. Its client is deliberately narrow
— one call, no model metadata, no tool execution, no retry policy.

## 3. Goals

- Provide a small, explicit canonical wire IR.
- Support multiple native protocol families with independent codecs.
- Preserve provider-specific data through raw/escape-hatch fields.
- Ship a one-call client on Finch whose JSON layer is replaceable.
- Keep auth keys caller-supplied, and keep model registries, tool execution,
  approval/audit policies and retries out of the core.
- Let applications plug in any tool-call framework.
- Make dialect adapters testable with fixtures, without network access.
- Make capability differences explicit instead of silently dropping fields.
- Keep OpenAI Chat Completions and OpenAI Responses as distinct protocols.

## 4. Non-goals

The core must not contain:

- API key storage, key lookup, OAuth or AWS signing
- model registry or capability database
- retry/backoff/rate-limit policy
- tool execution or callbacks
- approval, audit, or timeout policies
- conversation persistence or server-side state management
- evaluation, rerank, or embedding orchestration
- prompt templates, chains, memory, or agent loops

HTTP execution is in the core on Finch; JSON encoding is behind `LlmCall.JSON`
and can be replaced. SSE framing lives in `LlmCall.SSE`, and WebSocket
connections use the `LlmCall.WS` behaviour; neither is part of the completion transport. The core may define the **data**
needed by the layers above, but not implement them.

## 5. Design principles

1. **A wire protocol, not a provider.** A dialect codec describes a wire format.
   A provider is an endpoint plus authentication plus model availability.
2. **Canonical does not mean lossless.** Canonicalize common concepts; keep
   unknown/provider-specific data in `raw` or `provider_options`.
3. **No silent drops.** If a canonical field cannot be represented by a
   protocol, fail with a protocol/capability error or require an explicit
   provider option.
4. **Terms, not JSON strings.** Codecs return JSON-compatible Elixir terms.
   The client encodes them with `Config.json`.
5. **No hidden state.** Streaming and continuation state are explicit.
6. **Tool execution is outside.** Tool calls are data; running them is the
   application's job.
7. **Small core, one replaceable edge.** HTTP is Finch; JSON sits behind a
   behaviour with a default. A tool framework is used directly, not wrapped.
8. **No `term()` in canonical public fields.** Canonical fields use explicit
   unions/structs. `term()` is reserved for genuinely opaque adapter state (for
   example, a protocol stream state) and transport-decoded input at the
   behaviour boundary.

## 6. Approaches considered

### A. Transport-free codec library

Canonical IR and codecs only; the application owns HTTP, SSE and JSON.

- smallest dependency surface; usable from any stack
- every caller re-implements SSE framing, `[DONE]` handling and error mapping

This was the first shape of the library. Superseded because duplicating that
layer in every application cost more than shipping it.

### B. SDK with a replaceable JSON edge (chosen)

Canonical IR and codecs plus a one-call client on Finch; JSON lives behind
`LlmCall.JSON`, with Elixir `JSON` as the default; providers are user modules.

- one call works after `mix deps.get`
- the JSON module can be replaced per application, provider or client
- costs two runtime dependencies (Finch, Mint.WebSocket)

### C. Provider gateway

Built-in provider catalog, routing by model name.

- the most convenient first call
- the library inherits every base URL, auth shape and model rename, and it
  contradicts "no model catalog"

Rejected.

### D. Framework-specific adapters only

Implement adapters for one agent framework.

Rejected: duplicates protocol work across frameworks and creates no reusable
foundation.

## 7. Architecture

```text
                    +----------------------+
                    |   application / agent|
                    +----------+-----------+
                               |
             canonical request / response
                               |
                    +----------v-----------+
                    |      LlmCall      |
                    |  canonical wire IR   |
                    +----------+-----------+
                               |
                    +----------v-----------+
                    | LlmCall.Dialect.*  |
                    |  encode/decode       |
                    +----------+-----------+
                               |
                  encoded request / events
                               |
                    +----------v-----------+
                    |   LlmCall.HTTP      |
                    |       Finch         |
                    +----------+-----------+
                               |
                         HTTP / JSON
                               |
                    +----------v-----------+
                    |     LLM provider     |
                    +----------------------+
```

### Core layers

1. **Canonical IR** — request, messages, content, tool data, response,
   streaming events, usage, errors.
2. **Dialect codec** — encoding request terms and decoding response/event
   terms.
3. **Capabilities** — explicit protocol/model capability description.
4. **Client** — provider declaration, endpoint, auth shape, and the HTTP scope.
5. **Transport** — `LlmCall.HTTP` on Finch, and the `LlmCall.WS` behaviour for
   WebSocket connections. `LlmCall.JSON` is the one replaceable seam.

## 8. Canonical IR

The names below use the existing project namespace, `LlmCall`.

### 8.0 Single source of truth and raw capture

Normalized fields are the authoritative contract. `raw` is an optional,
immutable provider snapshot, never a second source that callers or codecs may
use to update canonical fields after decoding.

Rules:

- `raw` is `nil` by default.
- Raw capture is controlled by `LlmCall.Config.capture_raw`, and it covers every
  payload a codec keeps, `Error.raw` included:
  - `:none` — no raw payloads (default)
  - `:response` — retain the full response payload on `Response.raw`
  - `:all` — also retain provider events on `StreamEvent.raw`
- A provider error envelope is a response payload: `Error.raw` follows the same
  policy, so `:none` leaves it `nil`.
- A codec decodes normalized fields in one pass. It must not later overwrite
  them from `raw`.
- Do not store the same full payload in `Usage.raw`, `provider_metadata`, and
  `Response.raw`. Those duplicate slots are intentionally absent from this
  design.
- `ToolCall.raw_arguments` is an optional lossless wire projection. If present,
  `arguments` is the decoded form of `raw_arguments` (or `nil` when decoding
  fails); the two fields must not be updated independently.
- `Content.Raw` is only for an unknown content block. It is not a copy of the
  full provider response.
- `LlmCall` does not provide a JSON encoder; if raw payloads are persisted, the
  application decides whether to serialize them.
- The canonical response/content/usage should be sufficient for normal use;
  raw is for diagnostics, provider extensions, and future capabilities.

### 8.1 Request

A request is a `%LlmCall.Request{}` holding `model`, `system`, `messages`, `tools`,
`tool_choice`, `output`, `modalities`, `reasoning`, `params`, `provider_options` and
`stream`. `params` is an atom-keyed map of the six sampling and length controls
(`temperature`, `top_p`, `top_k`, `max_tokens`, `stop`, `seed`); a `nil` value means
"provider default" and is not sent. The struct defaults are `tool_choice: :auto`,
`output: :text`, `modalities: [:text]`, `params: %{}`, `provider_options: %{}` and
`stream: false`.

Fields:

- `model` — provider/model identifier as understood by the selected protocol
  and endpoint.
- `system` — `nil`, a string, or a list of text parts. The codec decides where
  it belongs in the provider request.
- `messages` — user/assistant turns. Tool results are content parts, not a
  mandatory `:tool` role.
- `tools` — optional neutral tool specifications. A function tool's `name` must
  be unique within the list; each protocol identifies a tool by name, so a second
  entry under one name is a `:validation` error. The name must also match the
  selected protocol's published class: OpenAI Chat allows `[a-zA-Z0-9_-]` up to 64
  characters, Anthropic the same class up to 128, Gemini the same plus `.` and `:`
  with a leading letter or underscore, and OpenAI Responses publishes no
  constraint. See [§8.12](#812-tool-names).
- `tool_choice` — `:auto | :none | :required | {:tool, name} | {:allowed, [name]}`.
  `{:tool, name}` and `{:allowed, names}` are cross-referenced against `tools`:
  a name no tool declares is a `:validation` error, because both OpenAI and
  Anthropic reject such a request (Anthropic: "tool_choice not in tools") and
  Gemini requires its `allowedFunctionNames` to match a `FunctionDeclaration.name`.
  Both sides live in the same request, so the mismatch is caught locally. A
  builtin tool's `name` counts as declared. An empty `{:allowed, []}` is rejected
  too: a protocol that derives `mode: ANY` from it would require a call while
  allowing none. `{:allowed, names}` is Gemini-only; the other codecs reject the
  form outright.
- `output` — `:text | :json_object | {:json_schema, name, schema, strict?}`. This
  describes the text format only.
- `modalities` — which output modalities the caller accepts, default `[:text]`.
  `[:text, :image]` means a response may contain generated image parts as well as
  text. It is a capability request, not a demand: `[:text, :image]` still allows a
  text-only response. See [Media generation](#23-media-generation-image-and-video).
- `reasoning` — optional `%LlmCall.Reasoning{}`; controls thinking/reasoning
  effort or budget where the protocol supports it. Provider-specific controls
  remain in `reasoning.provider_options`.
- `params` — common sampling/length controls. Both the key and the value are
  validated per protocol: a range or type the codec knows the provider rejects
  is a `:validation` error, never a value that reaches the wire. See
  [§8.11](#811-params-values).
- `provider_options` — explicit escape hatch for provider-specific options.
- `stream` — whether the caller wants streaming events.

`provider_options` is intentionally not a catch-all for values that the
canonical layer can represent. It is for features that are genuinely
provider-specific.

A codec reserves the wire keys it derives from the request envelope (`model`,
`messages`, `system`, `contents`, `tools`, `stream`), so a request-level override
is a validation error. Parameter-level native keys stay reachable:
`provider_options.gemini.generationConfig.candidateCount` or a nested
`tool_choice.disable_parallel_tool_use` are explicit caller intent, merged beside
the canonical values. `Config.default_provider_options` may not override a
parameter-level canonical field, so a default cannot silently beat an explicit
request. Reasoning-specific native controls belong on
`Reasoning.provider_options`, which merges into the protocol's reasoning object
(and is therefore subject to the same reserved-key rule, because OpenAI Chat
merges it into the body root).

The namespace keys are checked, not just their values: a codec names the
namespaces it reads (`:openai`, `[:gemini, :google]`, ...) and rejects any other
key in a **request**, so `provider_options: %{openai_chat: ...}`, a string key, or
a present-but-`nil` namespace is a validation error rather than a silently ignored
option. `Config.default_provider_options` is application-wide: only the
namespaces this codec reads are checked there, so one `Config` can carry defaults
for several providers.

A nested native object stays reachable in both sources, with its canonical keys
reserved: `generationConfig.candidateCount` and
`stream_options.include_obfuscation` are accepted, `generationConfig.temperature`
and `stream_options.include_usage` are not, because the codec derives those from
`params`.

#### Fields a protocol cannot carry

A protocol with no wire field for a canonical value must reject it, not drop it —
except for the fields below, which are local to the IR and never meant to reach a
provider. They are listed deliberately so a reviewer does not have to rediscover
them:

- `ToolCall.index` — stream bookkeeping. `LlmCall.StreamAssembler` keys
  fragments by it; a request tool call has no index on the wire.
- `Content.Image.media_type` when `source` is a URL (Anthropic): the protocol
  infers the type from the URL, and its `image` block has no `media_type` for that
  source. Base64 sources do carry it.
- The `name` in `output: {:json_schema, name, schema, strict?}` (Gemini): Gemini's
  `responseSchema` has no schema name. The name stays a caller-side label; the
  codec keeps the schema and drops the label. OpenAI emits it; Anthropic rejects
  structured output entirely. Gemini validates `responseSchema` with the same
  subset checks as tool `parameters`.
- `Request.modalities` equal to `[:text]` (the default) — the protocol default, so
  it is omitted rather than written.

Everything else is a rejection: an unsupported content variant
(`Content.Video` in a chat request), `ToolSpec.strict` on Anthropic or Gemini,
`{:allowed, names}` on OpenAI or Anthropic, and a `params` key the codec does not
implement.

`test/llm_call/write_path_audit_test.exs` enumerates every canonical-derived
wire key and asserts each is rejected from every source that can write it, so
this list is the only place a dropped field may be added.

The decode side has the mirror problem: a provider field can be ignored. Envelope
data, echoes (`choices[].index`, `candidates[].index`), discriminators
(`tool_calls[].type`, `"type" => "message"`), and an implied role
(`message.role`) are deliberately not modelled; they remain reachable through
`Response.raw` when `capture_raw` keeps it.
`test/llm_call/decode_path_audit_test.exs` deletes every provider leaf and
requires the canonical struct to change, or the leaf to be listed with a reason.
Adding a field to a provider fixture without mapping it fails that test.

The streaming path has the same rule one level down:
`test/llm_call/stream_delta_audit_test.exs` deletes each chunk leaf and
compares the whole `{type, delta, index}` event list, so every `StreamDelta` field
and every `StreamEvent.index` has a provider source. The same mutation applied to
a field the codec does not know about must produce a `Raw` event, never silence.

### 8.2 Message

A message is a `%LlmCall.Message{}`: `role` is `:user` or `:assistant`, and
`content` is a list of content parts.

System instructions stay in `Request.system`, because provider placement
differs:

- OpenAI Chat: system/developer message
- OpenAI Responses: `instructions`
- Anthropic: top-level `system`
- Gemini: `systemInstruction`
- Bedrock Converse: top-level `system`

Tool results are content parts inside a user message — a `%LlmCall.ToolResult{}`
with `call_id`, `name`, `content` (a string or text parts) and `is_error`.

Adapters translate this into provider-specific forms:

- OpenAI Chat: `role: "tool"` message
- OpenAI Responses: `function_call_output` input item
- Anthropic: `tool_result` content block
- Gemini: `functionResponse` part
- Bedrock Converse: `toolResult` block
- Cohere: `tool` message

### 8.3 Content parts

Initial canonical content types:

- `%LlmCall.Content.Text{text: String.t()}`
- `%LlmCall.Content.Image{source: source(), media_type: String.t() | nil}`
- `%LlmCall.Content.File{source: source(), media_type: String.t() | nil, filename: String.t() | nil}
- `%LlmCall.Content.Video{source: source(), media_type: String.t() | nil}`
- `%LlmCall.ToolCall{}`
- `%LlmCall.ToolResult{}`
- `%LlmCall.Content.Thinking{text: String.t(), signature: String.t() | nil}`
- `%LlmCall.Content.Raw{type: String.t() | nil, data: map()}`

`ToolCall` and `ToolResult` are the shared canonical structs defined below; there
are no duplicate `Content.ToolCall` or `Content.ToolResult` wrappers.

A media part validates its own payload, not only its shape: a `{:base64, data}`
source must be base64 (padding may be omitted, as the canonical examples spell
it), and a `media_type` must be a `type/subtype` rather than free text. A codec
with no wire field for a part still reports the payload problem first, because
payload validation runs before the per-codec shape check.

`Raw` is an escape hatch for provider-specific blocks that the codec does not
understand. It must be preserved in canonical responses and rendered back when
possible.

#### Replay

A response that can be decoded but not sent back makes a tool loop impossible, so
which content parts a codec accepts in an assistant message is part of the
contract. The answers differ because the request shapes do:

| Part | OpenAI Chat | OpenAI Responses | Anthropic Messages | Gemini GenerateContent |
| --- | --- | --- | --- | --- |
| `Content.Text` | yes | yes | yes | yes |
| `ToolCall` | yes | yes | yes | yes |
| `Content.Thinking` with `signature` | rejected | rejected | yes | yes |
| `Content.Thinking` without `signature` | rejected | rejected | rejected | yes |
| `Content.Raw` | rejected | rejected | yes | yes |

"Rejected" is a `:validation` error that names the part, never a silent drop.
OpenAI's request bodies are closed sets, so no provider-specific block can go back
in, and its reasoning output is not replayable either — Responses continues the
conversation with `previous_response_id` instead. Anthropic rejects an unsigned
thinking block because its API does. Gemini accepts an unsigned one because its
API only requires a signature where a tool call follows the thought.

`Content.Raw` is rendered back as its `data` alone: a block decoded from a provider
already contains the discriminator, so `type` stays a caller-side label. A block
built by hand must therefore carry the discriminator inside `data`.

`LlmCall.Codec.Conformance.assert_replays/3` pins this table per codec.

### 8.3.1 Reasoning

Reasoning config is separate from `params` because providers expose different
axes:

`%LlmCall.Reasoning{}` carries `effort` (`:none | :minimal | :low | :medium |
:high | :xhigh | :max | nil`), `budget_tokens` (a positive integer or `nil`),
`summary` (`:auto | :concise | :detailed | nil`) and `provider_options` (a map).

- `effort` is a canonical hint, not a guarantee that every provider accepts
  every value. `nil` means the provider/model default.
- `budget_tokens` is for providers that expose an explicit thinking budget.
- `summary` is for providers that expose a separate reasoning-summary control;
  `nil` means "do not ask for one".
- A provider adapter maps `effort`/`budget_tokens`/`summary` to its native
  fields; if it cannot express a non-nil canonical field, it must return a
  validation/capability error rather than silently dropping it.
- `provider_options` is for native controls with no canonical equivalent.

Examples:

- OpenAI: `reasoning.effort` on Responses; `reasoning_effort` on Chat.
- Anthropic: adaptive thinking / budget thinking and effort controls; exact
  shape depends on the API version.
- Gemini: `thinkingConfig` level or budget, depending on model.
- Bedrock/other: native provider fields through the adapter or
  `provider_options`.

### 8.4 ToolSpec

`%LlmCall.ToolSpec{}` carries `kind` (`:function` or `:builtin`), `name`,
`description`, `parameters` (a JSON Schema object or `nil`), `strict` (`nil` or a
boolean) and `provider_options`.

- `parameters` is a JSON Schema object (`map()`), not a JSON string or a
  provider-specific schema struct. It must already be in the selected codec's
  dialect. The Gemini codec validates the OpenAPI subset and returns `:validation`
  for a lowercase `type`, `additionalProperties`, `$ref`/`$defs`, `prefixItems`,
  `oneOf`, `const`, `allOf` or `not`. OpenAI's `strict: true` mismatch is not
  locally detectable and remains a provider error. `nil` is valid for a built-in
  tool that has no function schema.
- `kind: :function` is the normal function-tool case.
- `kind: :builtin` is a provider-hosted tool (web search, grounding, server
  tools). Its `name` is the **vendor's own identifier** (`web_search_20250305`,
  `google_search`), and its native knobs go in `provider_options`, merged into the
  codec's tool shape. `parameters` and `strict` are rejected for this kind,
  because a hosted tool has no local schema.
- The library never interprets a hosted tool's name; it answers only "will this
  codec forward it?" through `Capabilities.builtin_tools`.
- No callback, function, approval policy, or execution metadata belongs here.
- `strict` is optional; dialect adapters reject it when unsupported or map it
  to their equivalent.

### 8.5 ToolCall

`%LlmCall.ToolCall{}` carries `id`, `name`, `arguments`, `raw_arguments`,
`arguments_error` (`nil | {:invalid_json, reason} | :no_json_decoder`) and `index`.

The `arguments` map is the decoded form where decoding is safe. Keep the raw
JSON string because:

- OpenAI Chat and Cohere carry arguments as a JSON string.
- Anthropic, Gemini, and Bedrock commonly carry a decoded object.
- Applications may need to preserve invalid or partial fragments.
- Some frameworks expect the raw string.

`id: nil` is valid because Gemini `functionCall` does not have a call id.

When `raw_arguments` is present, `arguments` is its decoded value. If decoding
fails, `arguments` is `nil` and `arguments_error` says why — `{:invalid_json,
reason}` for a payload that is not decodable JSON or not an object, and
`:no_json_decoder` when `LlmCall.StreamAssembler` was built without a decoder.
`reason` is a message, never the payload: `raw_arguments` is the only place the
payload travels. The codec must not silently turn malformed arguments into
`%{}`.

### 8.6 ToolResult

`%LlmCall.ToolResult{}` carries `call_id`, `name`, `content` (a string or text
parts) and `is_error`.

Adapters validate required identifiers:

- OpenAI Chat requires `call_id`.
- OpenAI Responses requires `call_id`.
- Anthropic uses `tool_use_id`.
- Gemini uses `name` and no id.
- Bedrock uses `toolUseId`.
- Cohere uses `tool_call_id`.

A result answers a call the model made, and both protocols reject a history where
that link is missing: OpenAI with "messages with role 'tool' must be a response to
a preceding message with 'tool_calls'", Anthropic with "unexpected `tool_use_id`
found in `tool_result` blocks". `Helpers.validate_tool_result_pairing/2`
therefore checks, for every codec, that a result's `call_id` names a tool call in
the **immediately preceding** message; anything else is a `:validation` error that
names the offending id and index. A result with no `call_id` is left to the codec,
because a protocol like Gemini identifies a call by name.

An assistant turn whose calls have **no** results is not rejected: a truncated
turn is the caller's decision, and only the protocol can say whether it is
recoverable.

Anthropic adds a positional rule the other protocols do not have: in the user
message that answers a call, every `tool_result` block must come **first**, before
any text, so text after the results is fine and text before one is a 400. The
Anthropic codec rejects the latter as a `:validation` error naming the message
index; the other codecs carry results in their own envelope (OpenAI's `tool`
message, Gemini's `functionResponse` part) and are unaffected.

### 8.7 Response

`%LlmCall.Response{}` carries `id`, `model`, `content` (content parts),
`stop_reason` (a member of the union in §8.13), `usage` and `raw`.

`content` is a list of content parts, not provider-specific `choices` or output
items. `raw` is a `map() | nil` provider snapshot, populated only when
`Config.capture_raw` is `:response` or `:all`.

`Response.raw` must not be treated as a second response model. Use
`content`/`usage`/`stop_reason`; use raw only when provider-specific information
was not represented canonically.

`LlmCall.Response.text/1` and `tool_calls/1` are conveniences over `content`; adding
more does not change the IR.

### 8.8 Usage

`%LlmCall.Usage{}` carries six counters — `input_tokens`, `output_tokens`,
`total_tokens`, `cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens` — each a
non-negative integer or `nil`.

Pricing and cost calculation are outside the core.

Cost is not a wire field. It depends on provider, model, region, cache
read/write pricing, batch/tier discounts, and reasoning-token pricing. The
canonical `Usage` records the token dimensions needed by an upper layer, but
`LlmCall` does not store price tables or computed cost. If an application needs
cost tracking, use an optional `llm_call_cost` package or its own model-pricing
layer. Provider-specific billing fields, if returned, belong in `raw` or a
provider-specific extension.

### 8.9 Error

`%LlmCall.Error{}` carries `kind`, `message`, `code`, `status`, `reason`,
`retryable?`, `retry_after_ms` and `raw`; `kind` is one of `:validation`,
`:invalid_response`, `:provider`, `:transport`.

`code` is the provider's machine-readable code as a string (OpenAI's `code`,
Anthropic's error type, Google's status such as `"RESOURCE_EXHAUSTED"`,
MiniMax's numeric code stringified). `status` is the HTTP status, and **only the
client sets it**: a codec never sees the response status, so it always leaves it
`nil`.

`reason` is the structured counterpart of a `:transport` message, and only the
client sets it: `{:unknown_pool, name}` when the configured Finch pool is not
running, `:exception` when the HTTP transport raised, `:disconnected` when the
Responses WebSocket is not connected, `{:interrupted, why}` when an in-flight
lane was dropped, `{:connection_exited, why}` when the WebSocket connection
process ended, and otherwise the transport's own reason (`:econnrefused`,
`:timeout`, `:closed`, `:nxdomain`, `{:tls_alert, ...}`). A codec leaves it
`nil`, and so does a failure that carries a `status`. Match on `reason` instead
of parsing `message`; a non-transport error never sets it.

`retry_after_ms` is transport metadata: the client parses the `Retry-After`
response header (delta-seconds or IMF-fixdate) and sets it on the error; a codec
leaves it `nil`. It is a hint, like `retryable?`; backoff policy stays outside.

`retryable?` is a hint with two signals, and the client takes their **union**:

- the codec's verdict on the provider's own code or status field
  (`rate_limit_exceeded`, `overloaded_error`, `RESOURCE_EXHAUSTED`, ...);
- the HTTP status, through `LlmCall.Error.retryable_status?/1` — `408`, `425`,
  `429`, `500`, `502`, `503` and `504`.

Neither overrides the other, because a false negative is the costly direction: a
`429` answered with a code the codec does not list — a provider that added a
rate-limit code, a proxy with its own body — must not read as "do not retry".
`:transport` errors have no codec verdict, so the status is their whole hint; the
same status is a *second* signal when a decoded error gets its `status` filled in,
which the client and the streaming path both do. The asymmetry this avoids:
before the union, a `429` with an unparseable body was retryable while a `429`
with a body naming an unknown code was not.

A failure whose body cannot be decoded at all — a gateway's HTML, a truncated
frame, a proxy's plain text — has nothing to put in `raw` or `code`, so the
`message` quotes an excerpt of what arrived (`LlmCall.Excerpt`, trimmed and capped
at 200 characters) together with the decoder's own reason. That covers the
streaming payload path, the request-body encoder and the response-body decoder;
without it every one of them read as a bare "is not JSON".

`raw` is the provider payload the error was decoded from, and it follows
`Config.capture_raw` like every other `raw`: it is `nil` unless the policy is
`:response` or `:all`.

`kind` says who is speaking:

- `:validation` — the request cannot be expressed (codec, or the client for an
  unencodable body or an undeclared codec name);
- `:invalid_response` — a payload could not be decoded, by the codec **or** by the
  client when a `2xx` body is not JSON;
- `:provider` — a provider error envelope, decoded by the codec, with `status`
  filled in by the client;
- `:transport` — never reached a provider: connection failure, timeout, or a
  non-`2xx` body that is not a JSON envelope.

A codec never produces `:transport`; the client never produces `:provider`.

`execute/2` and `fetch/2` are the exception: they perform a request the caller
already encoded, with no codec to decode an envelope, so they report any non-`2xx`
as `:transport` with `status` set. Use `complete/3`, `generate/3` or `poll/3` when
you want the provider envelope decoded.

### 8.10 Capabilities

Capabilities are explicit and per protocol/config. They are **protocol-level**:
`capabilities/2` takes the request for signature symmetry but does not inspect the
model; a model-specific limit surfaces as a provider error rather than a
fabricated local guess.

| Field | Values | What it says |
| --- | --- | --- |
| `tools` | boolean | function tools are accepted |
| `builtin_tools` | `false` / `:passthrough` / list of names | provider-hosted tools |
| `parallel_tool_calls`, `tool_choice` | boolean | |
| `structured_output` | `:none` / `:json_object` / `:json_schema` | |
| `modalities` | list of `:text`, `:image`, `:video` | |
| `image_input`, `file_input` | boolean | |
| `reasoning` | `%LlmCall.Reasoning.Capabilities{}` | `supported`, `efforts`, `default_effort`, `budget_tokens`, `adaptive`, `summary` |
| `streaming_tool_calls`, `streaming` | boolean | |
| `prompt_cache` | boolean | the protocol **reports** cache accounting in `Usage` |
| `stateful` | boolean | a conversation can continue server-side through `provider_options` |

`builtin_tools` declares provider-hosted tools: `false` rejects them,
`:passthrough` forwards any name the caller supplies, and a list forwards only
those names.

`prompt_cache` and `stateful` are **reporting** capabilities, not request ones.
`prompt_cache: true` says `Usage` carries `cache_read_tokens` and
`cache_write_tokens`; it does not say the IR can place a cache breakpoint,
because it cannot — there is no request field for one. `stateful: true` says the
protocol offers server-side continuation, reached through `provider_options`
(`previous_response_id`, `store`), not a canonical field. A caller that needs to
control either reaches for `provider_options`, whose keys the codec validates.

`validate_request/2` on a codec can reject unsupported combinations
before a transport sends anything. No silent field dropping.

### 8.11 `params` values

A `params` key is checked twice: the key must be one the protocol accepts, and
the value must be one it can send. The second half is per protocol, because the
same key has different bounds:

| Key | OpenAI Chat / Responses | Anthropic | Gemini |
| --- | --- | --- | --- |
| `temperature` | number `0..2` | number `0..1` | number `0..2` |
| `top_p` | number `0..1` | number `0..1` | number `0..1` |
| `top_k` | not accepted | integer `>= 0` | integer `>= 0` |
| `max_tokens` | integer `>= 1` | integer `>= 1`, required | integer `>= 1` |
| `stop` | string or up to 4 strings | string or string list | string or up to 4 strings |
| `seed` | integer | not accepted | not accepted |

A `nil` value means "provider default" and skips the value check entirely. A
`max_tokens` upper bound is model-level, not protocol-level, so it is not checked;
the model reports that as a provider error ([§2.2](#22-what-this-is-not)).

### 8.12 Tool names

A function tool is identified by `name` alone, so the name is validated twice: it
must be unique in the list (§8.1), and it must match the target protocol's
published class. The classes are per protocol because they genuinely differ:

| Protocol | Pattern | Max |
| --- | --- | --- |
| OpenAI Chat | `^[a-zA-Z0-9_-]+$` | 64 |
| OpenAI Responses | no published constraint | - |
| Anthropic Messages | `^[a-zA-Z0-9_-]+$` | 128 |
| Gemini `FunctionDeclaration` | `^[a-zA-Z_][a-zA-Z0-9_.:-]*$` | 128 |

Only Gemini admits `.` and `:` and requires a leading letter or underscore, so a
namespaced name such as `weather.get` is valid there and a `:validation` error on
OpenAI or Anthropic. A name that is legal everywhere within the 64-character
ceiling is `[a-zA-Z0-9_-]{1,64}`.

Responses publishes no pattern or length, so it forwards any name; inventing a
constraint it does not document would reject requests the provider accepts.

### 8.13 Canonical type specifications

Each canonical module's `@type t` is the authoritative shape, and ExDoc renders it
next to the module. What a shape cannot state is recorded here: which unions are
closed, and what each struct is for.

Four unions are closed, and changing one is an IR change:

```elixir
@type capture_raw :: :none | :response | :all
@type modality :: :text | :image | :video

@type wire_value ::
        nil
        | boolean()
        | number()
        | String.t()
        | [wire_value()]
        | %{optional(String.t()) => wire_value()}

@type stop_reason ::
        :end_turn
        | :tool_calls
        | :max_tokens
        | :stop_sequence
        | :content_filter
        | :error
        | :unknown
```

| Module | What it carries | Rules |
| --- | --- | --- |
| `LlmCall.Request` | model, system, messages, tools, tool_choice, output, modalities, reasoning, params, provider_options, stream | §8.1 |
| `LlmCall.Message` | role and a list of content parts | §8.2 |
| `LlmCall.Content.Text` / `.Image` / `.File` / `.Video` / `.Thinking` / `.Raw` | one content part each; a `source()` is a string, `{:url, _}`, `{:base64, _}` or `{:file_id, _}` | §8.3 |
| `LlmCall.Reasoning` / `LlmCall.Reasoning.Capabilities` | effort, budget_tokens, summary, provider_options; what a protocol supports | §8.3.1 |
| `LlmCall.ToolSpec` / `.ToolCall` / `.ToolResult` | tool wire data; no schema derivation, no dispatch | §8.4–§8.6 |
| `LlmCall.Response` | id, model, content, stop_reason, usage, raw | §8.7 |
| `LlmCall.Usage` | six token counters, provider-reported and token-only | §8.8 |
| `LlmCall.Error` | kind, message, code, status, reason, retryable?, retry_after_ms, raw | §8.9 |
| `LlmCall.Capabilities` | protocol-level support flags | §8.10 |
| `LlmCall.Config` | default_provider_options, capture_raw, json | §10, §16 |
| `LlmCall.EncodedRequest` | method, path, query, headers, body | §11 |
| `LlmCall.StreamState` | the owning codec plus opaque data | §12 |
| `LlmCall.Codec.Info` | name, protocol, wire version, ir_version | §10 |

`LlmCall.StreamEvent` and its `StreamDelta` types are specified in
[Streaming](#12-streaming).

## 9. OpenAI Chat Completions vs Responses

These are separate dialect adapters, not one endpoint toggle.

| Aspect         | Chat Completions                        | Responses                                      |
|----------------|-----------------------------------------|------------------------------------------------|
| Endpoint       | `/v1/chat/completions`                  | `/v1/responses`                                |
| Request        | `messages[]`                            | `input` items or string                        |
| System         | system/developer message                | `instructions`                                 |
| State          | stateless                               | optional `store` + `previous_response_id`      |
| Response       | `choices[0].message`                    | `output[]` items + `output_text`               |
| Tool call      | assistant `tool_calls`                  | `function_call` output item                    |
| Tool result    | `role: "tool"` message                  | `function_call_output` input item              |
| Built-in tools | limited function tools                  | broader built-in tools depending model/account |
| Streaming      | `choices[0].delta` chunks               | typed `response.*` events                      |
| Token limit    | `max_tokens` / `max_completion_tokens`  | `max_output_tokens`                            |
| Compatibility  | widely copied by OpenAI-compatible APIs | mostly OpenAI-native                           |

Implement as:

```text
LlmCall.Dialect.OpenAI.Chat         # POST /v1/chat/completions
LlmCall.Dialect.OpenAI.Responses    # POST /v1/responses
```

Both are implemented. The canonical IR is shared, but the response, event and
state mappings are independent. Responses is available over HTTP/SSE and, for
persistent multiplexed requests, over the WebSocket connection in §24.1.

OpenAI Responses state is deliberately provider-specific. `previous_response_id`
and `store` live in `Request.provider_options` (for example under an `:openai`
key) and are interpreted by the Responses adapter; `LlmCall` does not model
server-side conversation state. The canonical `Response.id` remains available
for the caller to continue the conversation.

## 10. Codec contract

`%LlmCall.Codec.Info{}` carries `name`, `protocol`, `version` and `ir_version`.

`name` identifies the codec instance and `protocol` the wire family; they are
equal for every codec today (one codec per family) and differ only when one
module serves a family with variants. `version` is the wire version the codec
targets — Anthropic's `2026-10-21`, Gemini's `v1beta`, Seedance's `v3` — and
`nil` when the protocol has no versioned surface (OpenAI Chat and Images).
`ir_version` is the canonical IR contract the codec was written against.

| Callback | Contract |
| --- | --- |
| `info/0` | `%LlmCall.Codec.Info{}` |
| `encode_request(request, config)` | `{:ok, %EncodedRequest{}}` or an error |
| `decode_response(term, config)` | `{:ok, %Response{}}` or an error |
| `validate_request(request, config)` | `:ok` or a `:validation` error |
| `capabilities(request, config)` | `%LlmCall.Capabilities{}` |
| `decode_error(term, config)` | `%LlmCall.Error{}`, never an error tuple |
| `init_stream(request, config)` | `{:ok, %StreamState{}}` or an error |
| `decode_stream_event(term, config, state)` | `{:ok, events, state}`, `{:done, state}`, or an error |
| `finish_stream(state, config)` | `{:ok, events, state}` or an error |

`init_stream/2`, `decode_stream_event/3` and `finish_stream/2` are optional, so a
non-streaming codec implements no dummy callbacks.

`LlmCall.Codec` is a behaviour. `LlmCall.Dialect.*` modules are concrete
dialects of one wire protocol; each implements that behaviour. The namespace is
`Dialect` rather than `Protocol` so it cannot be read as Elixir's `defprotocol`,
and the same word is used for the `use` macro (`LlmCall.Dialect.Adapter`,
`LlmCall.Media.Dialect.Adapter`).

`info/0` lets a codec declare its protocol name, wire version, and the canonical
IR version it implements. `init_stream/2`, `decode_stream_event/3`, and
`finish_stream/2` are optional so a non-streaming codec does not have to
implement dummy callbacks. When streaming is unavailable, the public API returns
a typed `LlmCall.Error` rather than raising.

Streaming state is never exposed as a bare `term()`: it is wrapped in opaquely typed
`LlmCall.StreamState{}`, and the public API checks `StreamState.codec(state) ==
selected_codec` before delegating, so passing an Anthropic state to the OpenAI codec
is a typed error. Codec implementations use `StreamState.data/1` and
`StreamState.new/2`; the `data` remains deliberately opaque.

`%LlmCall.Config{}` contains codec defaults and capture policy, not the canonical
model selection: `default_provider_options`, `capture_raw` and `json`.

`default_provider_options` is merged before `Request.provider_options`; the
request value wins per key, and a namespace present in both merges recursively,
so a nested native object keeps the config keys the request does not repeat.
`Request.model` is the only model selection.
`Config` does not contain credentials or a base URL.

### 10.1 Codec discovery and extension

Codec selection is explicit:

the module is passed to `LlmCall.encode/3`, or named by `codec:` on a call.

There is no provider or codec registry in the core. A higher-level client may
map provider/model names to codec modules, but `LlmCall` does not. This keeps a
new dialect adapter independent of model catalogs and authentication.

Adding a new codec should require only:

1. A module that `use`s `LlmCall.Dialect.Adapter` (or
   `LlmCall.Media.Dialect.Adapter`), declaring its `provider_options` namespaces
   (`@namespaces`, or `namespaces:` on the media macro) and supplying `@path`,
   `@headers`, `info/0`, `capabilities/0`, the protocol's own
   `validate_request/2`, and a private `body/2` that returns the wire body.
2. Dialect-specific request/response/stream fixtures.
3. Capability declarations for the models/endpoints the codec supports.

`use LlmCall.Dialect.Adapter, codec: :openai_chat` injects the behaviour, the
canonical aliases, `@codec`, and `encode_request/2`; `encode: false` leaves
`encode_request/2` to the codec when the path or method varies per request. The
macro reads `@path` and `@headers` once the module finishes and raises at compile
time if either is missing. The media macro additionally injects the shared
`validate_request/2` pipeline; its `namespaces:` option is required, so a new
media codec has to state which `provider_options` keys it reads.

Adapters should not hand-roll the shared rules: `LlmCall.Dialect.Helpers` is
the adapter-authoring surface, and reimplementing it produces adapters the
conformance suite cannot check consistently.

It should not require a change to canonical `Request`, `Message`, `Response`,
or `Tool` structs for already-representable concepts.

### 10.2 Canonical type evolution

Canonical IR changes follow these rules:

- Add new optional fields with defaults in a minor release.
- Add new content-part variants to the `Content.part()` union only when existing
  codecs can ignore them safely or return a capability error for them.
- Unknown provider content is preserved in `Content.Raw`; a codec must not
  discard it.
- `Raw` is an escape hatch, not a permanent substitute for a canonical type.
  When a provider feature becomes common, promote it to a typed content/field
  in a documented release.
- Removing or changing the meaning of an existing canonical field requires a
  major release.
- Adding an optional field with a default does not bump
  `Codec.Info.ir_version`; the version changes only when existing codecs must
  adapt to the change.
- Changing required codec callbacks, or making an optional streaming callback
  required, is a breaking change.
- `Codec.Info.ir_version` identifies the canonical IR contract a codec was
  implemented against.

### 10.3 Codec conformance tests

The conformance suites are published from `lib/` so adapter packages can call
them:

```text
lib/llm_call/conformance.ex          # shared assertions
lib/llm_call/codec_conformance.ex    # LlmCall.Codec.Conformance
lib/llm_call/media/conformance.ex    # LlmCall.Media.Conformance
```

They are test support, not runtime dependencies: they `import
ExUnit.Assertions` (part of every Elixir installation) and are meant to be
called from a test.

What they check today:

- `info/0` metadata
- streaming-callback presence matching `capabilities.streaming` (and
  `decode_operation/2` matching `LlmCall.Media.Capabilities.async`)
- encoded path/method/body, a map-shaped query, and credential-free headers
- response decoding at the IR boundary: canonical parts, a stop reason from the
  closed union, canonical usage, and `raw` as a map or `nil`
- a malformed response as a typed `:invalid_response` error, never a raise or a
  fabricated response
- provider error envelopes as a canonical `%Error{}`: string-or-nil code, `status:
  nil`, boolean `retryable?`
- stream event shape and order, driven over the caller's chunks
  (`assert_stream/3`); `:message_delta` may carry `StreamDelta.Raw` for an
  unmapped provider field, and `{:done, state}` must not be followed by content
- streamed tool-call assembly through `LlmCall.StreamAssembler`
  (`assert_tool_call_assembly/5`)
- the *encoding* side of streaming (`assert_stream_request/3`): `stream: true`
  and `stream: false` must encode differently, the streaming request must carry
  a signal — `body["stream"]`, an SSE query, or a path that differs from the
  plain one — and the non-streaming request must not. A codec can implement every
  streaming callback and still never ask for SSE; nothing else in the suite
  catches that. The signal check is a disjunction, so `require:` pins the ones a
  protocol cannot lose (Gemini needs both `alt=sse` and the streaming path).
- the reserved-key rule (`assert_reserved_options/4`): each of the codec's own
  wire keys is rejected as a `provider_options` entry, which is the
  "no silent override" promise as a test.
- `capture_raw` on `Response.raw`, `StreamEvent.raw`,
  `LlmCall.Media.Response.raw`, and `Operation.raw`
- stream roundtrip and stream-state ownership (the request is passed in, so an
  out-of-tree codec is checkable)
- `Operation` state-machine invariants
- capability declarations matching validation, in both directions, for **media**
  and **chat** codecs (`assert_capability_consistency/3` on both sides)
- rejection of a request with a field the codec cannot express
  (`assert_rejects/3`) — the "no silent drops" promise as a test

What no generic suite can check is usage *mapping* (which provider field lands in
which counter) and whether a decoded text matches the provider's semantics; an
adapter covers those with its own fixture assertions. C1 is closed.

### 10.4 Native provider options

`provider_options` is a namespaced escape hatch, not a free-for-all: each codec
declares the native keys it knows and a small type contract for them. Known keys
are validated (`:boolean`, `:string`, `:map`, `:list`, `:number`, `:integer`, or
an enum); an invalid value is a `:validation` error. Unknown keys still pass
through, because a provider may add a field before the codec learns about it.

This is documentation plus early diagnostics, not a catalog: the codec does not
infer model support, pricing, or routing from an option. The first schemas cover
OpenAI Responses (`access_programs`, `store`, `previous_response_id`, `include`,
`parallel_tool_calls`, `truncation`, `background`, `service_tier`,
`safety_identifier`, `prompt_cache_key`), OpenAI Chat (`logprobs`, `top_logprobs`,
`logit_bias`, `stream_options`, `parallel_tool_calls`, `service_tier`, `user`,
`store`, `metadata`, `prediction`, `modalities`, `audio`, `web_search_options`),
Anthropic Messages, and Gemini GenerateContent.

## 11. Encoded request boundary

An encoded request is an `%LlmCall.EncodedRequest{}` with `method`, `path`, `query`,
`headers` and `body`.

- `path`, `query`, `headers`, and `body` are protocol-level facts.
- `body` is a JSON-compatible term, not an encoded JSON string.
- Headers may include required protocol headers.
- Headers must not include credentials; authentication is added by the client,
  from the provider's `auth` shape and the caller's `api_key`.
- The client prepends the base URL, merges the provider's `query:` under the
  encoded query, and performs JSON encoding with the configured module. The
  provider-level parameters carry vendor facts that are not protocol facts —
  MiniMax's `GroupId`, Azure OpenAI's `api-version` — and a codec's own key wins
  on a collision, because `alt=sse` belongs to the protocol.

The client is the default consumer:

build it with `MyApp.OpenAI.client(api_key: ...)`, then call
`LlmCall.complete(client, request)`.

The boundary stays public for callers that own a transport:

encode with `LlmCall.encode/3`, serialise `encoded.body`, and issue the request with
`encoded.method`, `encoded.path`, `encoded.headers` and `encoded.query`.

## 12. Streaming

The client parses SSE (`LlmCall.SSE`) and yields normalized events; codecs see
provider event terms only.

| Event type | Delta | Meaning |
| --- | --- | --- |
| `:message_start`, `:content_start`, `:content_stop`, `:message_stop` | none | structural |
| `:text_delta` | `%StreamDelta.Text{text}` | answer text |
| `:thinking_delta` | `%StreamDelta.Thinking{text, signature}` | reasoning text, or its signature |
| `:tool_call_start` | `%StreamDelta.ToolCall{id, name, index}` | opens a call |
| `:tool_call_delta` | `%StreamDelta.ToolCall{arguments}` | appends an argument fragment |
| `:tool_call_stop` | `%StreamDelta.ToolCall{}` | closes a call |
| `:message_delta` | `%StreamDelta.MessageDelta{stop_reason, usage}`, or `%StreamDelta.Raw{data}` | stop reason or usage; `Raw` when a provider field is unmapped |
| `:error` | none | the provider reported a failure |

`type` is a closed union of those names, and no caller should have to pattern-match
provider JSON. `raw` (a map or `nil`) is populated only when
`Config.capture_raw == :all`.

`delta` is a closed union of those delta structs. It must not be `term()`, and each
delta type must be usable without pattern-matching raw provider JSON. `raw` is
provider-specific but still typed as a JSON object (`map()`) or `nil`, and it is
populated only when `Config.capture_raw == :all`, so normal streaming does not retain
a second full event per chunk. If a provider sends a non-object sentinel, the
transport or codec normalizes it to `{:done, state}` or wraps it in a map; it must not
leak an arbitrary term into the public type.

A reasoning block is not one event: the text arrives incrementally, and a provider
that signs its thinking blocks — Anthropic on every block, Gemini on the thought
parts before a function call — sends the signature in a separate event whose `text`
is `""`. A caller that folds only `text` builds a block the next request cannot
carry: the fold has to append `delta.text` and keep `delta.signature` when it is set.

### 12.1 Streaming tool-call assembly

The wire layer can emit tool-call fragments before the model has finished its
output. A separate, pure `LlmCall.StreamAssembler` turns those fragments into
complete `LlmCall.ToolCall` values.

`LlmCall.StreamAssembler` is opaque: `new/1` takes an optional `json_decoder`,
`feed/2` returns `{:ok, assembler, completed_calls}`, and `finish/1` flushes whatever
is still pending.

Rules:

- Pending calls are keyed by `StreamEvent.index`.
- `:tool_call_start` records `id` and `name`.
- `:tool_call_delta` appends the `arguments` string fragment.
- `:tool_call_stop`, `:content_stop`, or `:message_stop` finalizes pending
  calls.
- `finish/1` finalizes any calls that did not receive an explicit stop event.
- Tool calls with multiple entries are independent and may complete at
  different times.
- The assembler does not execute tools and does not send tool results.
- A completed call may be emitted before `:message_stop` when the provider
  emits a per-block stop. The caller may start local side effects then, but it
  must send the tool result in the next model request after the current
  response completes.

The core does not depend on a JSON codec: `new/1` accepts an optional
`json_decoder`, receiving the accumulated argument string and returning `{:ok,
map()} | {:error, String.t()}`.

`json_decoder` receives the accumulated argument string and returns
`{:ok, map()} | {:error, String.t()}`. If no decoder is provided, the assembler
returns the complete `ToolCall` with `arguments: nil` and
`arguments_error: :no_json_decoder`. If decoding fails, the field carries
`{:invalid_json, reason}` — the decoder's own message when it returns a string,
and a fixed phrase otherwise — while `raw_arguments` preserves the payload.

Provider timing differs:

| Dialect | Tool-call completion signal | Early execution before message end |
| --- | --- | --- |
| OpenAI Chat Completions | `finish_reason: "tool_calls"` / final chunk | normally at message end |
| OpenAI Responses | `response.output_item.done` for the function call | often before response end |
| Anthropic Messages | `content_block_stop` for the tool block | yes, when the block stops |
| Gemini GenerateContent | complete `functionCall` part | yes |
| Bedrock Converse | tool-use block stop / message stop | provider-dependent |
| Cohere Chat | final tool-call chunk / finish reason | usually at response end |

Early execution is an application decision. `LlmCall` only exposes complete
calls; it does not run them or insert results into an active response.

`LlmCall.stream/3` owns the transport side.

`on_event:` is an observer, not a middleware: a 1-arity function called for every
event before the reducer, including `finish_stream/2` output. Its return value is
ignored, it cannot filter or replace events, and it stops being called after the
reducer halts. An application that needs to modify the stream combines the
`Enumerable` with `Stream.map/2`; raw HTTP bytes are not exposed as a hook.
There is no tee: reducing a `%LlmCall.Stream{}` twice issues the request twice.

- parse SSE framing (`LlmCall.SSE`)
- decode JSON payloads with `Config.json`
- detect provider stream terminators such as `[DONE]` and call
  `finish_stream/2`
- raise `LlmCall.HTTP.Error` when the body fails mid-stream

A caller that owns a transport does the same four steps itself before calling
`decode_stream_event/3`.

`LlmCall.SSE` keeps the server's `retry:` hint on the state as `retry_ms` instead
of dropping it, so a caller that owns reconnection policy can read it; the
library never reconnects a stream on its own. A pending event is capped at 1 MiB:
a peer that never sends the blank line ending an event raises
`LlmCall.SSE.Error` rather than growing the buffer without bound, and
`LlmCall.Stream` reports that as an `:invalid_response` `LlmCall.HTTP.Error`. The
frame is never truncated, because a truncated event would decode as a shorter
payload that still looks valid.

Codec responsibilities:

- turn provider event terms into normalized events
- maintain protocol-specific stream state
- preserve unknown events in `Raw`
- return `{:done, state}` when the protocol has a terminator

Tool-call assembly is a separate pure helper, for example:

```text
LlmCall.StreamAssembler
```

It may combine tool call deltas into complete `ToolCall` values, but it must not
execute them.

## 13. Tool framework integration

The core only defines tool wire data. It does not call tools.

### `tool_call`

`LlmCall` does not wrap `tool_call`: the application maps `ToolCall.describe/2` into
`%LlmCall.ToolSpec{}` values, and after decoding dispatches each call through
`ToolCall.run/4` with `call.name` and `call.arguments`. The library neither runs the
call nor builds the follow-up request.

Dependency direction:

```text
llm_call              no tool_call dependency
tool_call                no llm_call dependency
```

### Other frameworks

Any framework can map its own tool definition to `LlmCall.ToolSpec` and consume
`LlmCall.ToolCall` / `LlmCall.ToolResult`. No framework is privileged.

### MCP

MCP is a tool/resource transport, not an LLM completion protocol. An MCP tool
catalog can be converted into `LlmCall.ToolSpec` values outside the core.

## 14. Dialect adapters
### Phase 1

- `LlmCall.Dialect.OpenAI.Chat`
- `LlmCall.Dialect.OpenAI.Responses`
- `LlmCall.Dialect.Anthropic.Messages`
- `LlmCall.Dialect.Gemini.GenerateContent`

These cover the most common request/response shapes and validate the canonical
IR.

### Vendored media adapters

These ship in this repository under `LlmCall.Media.Dialect.*`. They are not
part of the stable API surface: a provider API change can force an adapter change
in a minor release, which is why they are named separately from the reference
adapters. See `LlmCall.Media` for the contract.

- `LlmCall.Media.Dialect.OpenAI.Images`
- `LlmCall.Media.Dialect.Gemini.Predict` (Imagen)
- `LlmCall.Media.Dialect.Seedance.Video`
- `LlmCall.Media.Dialect.MiniMax.Video`

### Beyond this repository

There is no roadmap of adapters the library owes, and no provider list to
complete. An adapter that is not vendored here is an application module or a
package, in or outside this repository, following the same behaviour and the
same conformance suite. `CONTRIBUTING.md` states the bar.

### OpenAI-compatible APIs

Do not create a separate protocol for every OpenAI-compatible provider.

Use the OpenAI Chat codec with a provider/endpoint configuration:

- base URL
- auth headers
- model id
- capability flags
- provider-specific path/query

Examples include Groq, DeepSeek, Together, Fireworks, OpenRouter, xAI, vLLM,
LM Studio, and Ollama's OpenAI-compatible endpoint. Their compatibility is not
uniform; capabilities must be explicit.

### Provider/protocol routing

A provider is not a protocol:

- Azure OpenAI uses OpenAI Chat/Responses shapes with deployment and API-version
  configuration.
- Vertex AI can route Gemini-shaped and Anthropic-shaped models.
- Bedrock can expose Converse, Anthropic Messages, and OpenAI-compatible
  surfaces depending on the model/endpoint.

The dialect adapter is selected independently from the provider endpoint.

## 15. Module layout

`lib/llm_call/` holds the core: canonical structs, the two codec behaviours, the
client, the Finch transport, the SSE parser and the pure stream assembler.
`dialect/*` holds the **reference adapters** — the protocol families the IR is
written against — and `media/dialect/*` the **vendored** media adapters, which ship
with the library but are not part of the stable surface. `mix docs` lists every
module; the file tree is not repeated here, and nothing in the core depends on a
dialect module: an adapter is selected by name at call time.

Optional packages live outside this repository: `llm_call_cost` for pricing and
`llm_call_langchain` for a LangChain adapter. `LlmCall.HTTP` is Finch and
`LlmCall.WS.Mint` is the WebSocket implementation; there is no HTTP behaviour and no
tool behaviour (`tool_call` is a companion the application adds itself).

Test support and the compiled examples are not part of the design: `test/support/`
holds the fixture payloads, the two test servers, the JSON doubles and the codec
fakes, and `examples/` holds provider modules compiled in `:dev` and `:test` so they
cannot rot.

## 16. Public API

Two tiers. The one-call client is the default:

`complete/3`, `stream/3` and `generate/3` take a client, the request and the call
options (`codec:`, `headers:`, plus `on_event:` on `stream/3`); `poll/3` advances a
media operation; `execute/2` and `fetch/2` run a request the caller already encoded.

A caller that owns a transport keeps the encode/decode boundary:

`encode/3`, `decode_response/3`, `init_stream/3`, `decode_stream_event/4`,
`finish_stream/3`, `validate_request/3`, `capabilities/3`, and
`StreamAssembler.new/1`, `feed/2`, `finish/1`.

`headers:` is a list of string `{name, value}` pairs for this call only. The
client merges them in this order: client/provider headers, then call headers,
then the codec's encoded headers. Later entries win, so a call can override a
provider default (a gateway routing header, a beta flag), while a protocol
header emitted by the codec still wins. An invalid list is a `:validation`
error before any request. Any option outside the ones a call lists is a
`:validation` error too, so a misspelled `codec:` cannot silently fall back to
the default. WebSocket handshake headers are connection-level:
pass `headers:` to `Connection.start_link/1`; they are merged with the client
headers and reused on reconnect.

`encode` returns `{:ok, %LlmCall.EncodedRequest{}}`; the media operations return
their documented success/error tuples, and `capabilities` and `media_capabilities`
return `{:ok, struct} | {:error, %LlmCall.Error{}}`.

A request of the wrong shape is part of that contract, not a reason to raise: a
caller that assembles a `%LlmCall.Request{}` from data gets a `:validation` error
naming the expected struct, on every dispatch function **and** on every top-level
call. `decode_response/3`, `decode_error/3` and `decode_operation/3` take a wire
term by design, so any term reaches the codec and comes back as a typed error
there.

A top-level call takes two structs, so the error names the one that did not
match: a bad client reports `%LlmCall.Client{}`, a bad request reports
`%LlmCall.Request{}`. Every function whose `@spec` promises
`{:ok, _} | {:error, %LlmCall.Error{}}` keeps that promise for any argument.

JSON resolution has a compile-time default and runtime overrides: the default is
read with `Application.compile_env(:llm_call, :json_library, ...)` and is Elixir
`JSON`, so changing it recompiles the library, while a provider declaration, a
client `json_library:` option or an explicit `%LlmCall.Config{}` overrides it.
`LlmCall.JSON.encode/2` and `decode/2` accept a module with tagged
`encode/1`/`decode/1` (Torque, Jason, Poison) or bang `encode!/1`/`decode!/1`
(Elixir `JSON`) and normalize to tagged tuples.

`capture_raw` has the same shape — `Application.compile_env(:llm_call,
:capture_raw, :none)`, overridden by `%LlmCall.Config{}` — and there is no provider
or call-level capture option.

Dispatch never raises for a module that implements the other behaviour: each
entry checks a behaviour-unique callback (`encode_request/2` for completion,
`encode_submit/2` for media) and returns a `:validation` error. The exception is
`decode_error/3`, whose callback exists in both behaviours.

## 17. Testing

The core suite must not need a live API. Every adapter is pinned with fixtures it
supplies, and the suite proves four things beyond the happy path:

- **Request fixtures** — a canonical request to an exact body, path, query and
  headers; tool definitions and tool choice; system placement; multi-modal content.
- **Response and stream fixtures** — text, tool calls, multiple blocks,
  usage/stop-reason mapping and provider errors; for streams, fragmented arguments,
  multiple calls by `index`, early completion, the terminator, unknown-event
  preservation and `capture_raw` at `:none`/`:response`/`:all`.
- **Capabilities and contracts** — an unsupported field is rejected rather than
  dropped, a declared capability accepts its representative, cost is never
  fabricated, and handing a streaming call to a non-streaming codec or a
  `StreamState` to the wrong codec is a typed error.
- **Audits** — three mutation suites keep silent drops out:
  - encode: every canonical-derived wire key is rejected from every source that can
    write it (§8.1);
  - decode: deleting a provider field either changes the canonical struct or is
    listed as an ignored envelope/echo field, and never raises; an absent field is
    `nil`/`:unknown`, never a fabricated value;
  - stream deltas: the same audit over chunks, so every `StreamDelta` field
    (`text`, `thinking`/`signature`, tool-call `id`/`name`/`arguments`/`index`,
    `stop_reason`/`usage`) and every `StreamEvent.index` has a provider source, and
    an unmapped field becomes a `Raw` event.

The audit suites live in `test/llm_call/` (`write_path_audit_test.exs`,
`decode_path_audit_test.exs`, `stream_delta_audit_test.exs`), and the published
conformance assertions run over every adapter this package ships.

## 18. Failure and compatibility policy

- Provider-specific features are opt-in through explicit fields or
  `provider_options`.
- Unsupported canonical fields produce `LlmCall.Error{kind: :validation}` or a
  capability error.
- Unknown provider blocks are retained as `Content.Raw`; full response raw is
  retained only when `capture_raw` requests it.
- The canonical IR is versioned; breaking changes require a major release.
- `raw` data is never part of the stable cross-provider contract; it is a
  best-effort escape hatch.
- New provider capabilities should be added through provider options before
  becoming canonical fields.

## 19. Anti-goals

The project moved from a transport-free codec library to a call-oriented SDK.
Three previous anti-goals were reversed deliberately; the rest stand.

No longer anti-goals:

- **A `Finch` dependency.** It is a required runtime dependency, because the
  one-call path must work after `mix deps.get`.
- **A fixed HTTP client.** `LlmCall.HTTP` is Finch; it is not a seam. JSON
  remains replaceable through `LlmCall.JSON`.
- **A tool runner.** Still an anti-goal, and now there is no tool adapter either:
  schema derivation and dispatch belong to `tool_call` or an application module,
  and building the follow-up request stays with the caller.

Still anti-goals; if they appear, the design has drifted:

- API-key lookup (the key is always passed in)
- `generate_text`-style prompt helpers beyond `complete/3`
- a model catalog or provider registry (providers are user modules, passed
  explicitly)
- an agent loop
- a prompt template or memory system
- automatic retries, backoff, or rate limiting (a timeout is configuration)
- provider-specific branches in user application code beyond the provider module
- a canonical model of individual hosted tools

## 20. Decisions

Settled:

1. **Core transport:** the library ships one HTTP client on Finch; there is no
   HTTP behaviour. Was "stay transport-free", then "replaceable transport";
   now fixed. JSON remains the replaceable edge.
2. **JSON encoding:** the client encodes and decodes with the configured module;
   codecs use the same module for tool-call arguments. Was "transport encodes".
3. **Tool data in core:** neutral `ToolSpec`, `ToolCall`, `ToolResult`; no schema
   derivation, no dispatch, no dependency on `tool_call`. An application maps
   `ToolCall.describe/2` into `ToolSpec` itself.
4. **First protocol set:** OpenAI Chat, Anthropic Messages, Gemini
   GenerateContent.
5. **OpenAI Responses:** a core reference adapter over HTTP/SSE and the
   Responses WebSocket connection.
6. **Stream assembler:** pure helper in core, protocol-neutral.
7. **SSE parser:** in core, because the default client streams.
8. **Codec discovery:** explicit codec module selection, named on a provider
   module; no core model catalog or registry.

## 21. Implementation order

The order the release followed, and what it taught, are recorded in
[roadmap.md](roadmap.md).

## 22. Design success criteria

This design is working if:

- A caller can use `LlmCall` without any agent framework.
- A third party can write an adapter, decode against their own fixtures, and
  verify its shapes, capture policy, stream plumbing, capabilities, and operation
  states with the conformance suite — without touching core.
- An adapter outside this repository needs no core release; a vendored one is
  allowed to change with its provider without changing the IR.
- A caller reaches a provider with one function, without assembling a request or
  parsing SSE.
- The JSON layer can be replaced without touching a codec, per application, per
  provider, or per client; HTTP is Finch.
- A tool framework can be used directly; the library models tool wire data only
  and depends on no tool library.
- Adding a dialect adapter does not require changing canonical messages.
- Provider-specific features remain accessible through explicit escape hatches.
- The core has no auth lookup, model catalog, provider registry, or agent loop.
- Dialect fixtures are readable and testable without network access.
- A caller can generate images and run video generation jobs without writing
  provider-specific HTTP, and without the core polling or downloading anything.

## 23. Media generation (image and video)

The media **IR** is first-class and stable; media **adapters** are vendored
under `LlmCall.Media.Dialect.*` and are not part of the stable surface. It uses
two entry points over one content vocabulary:

- a completion that may return generated media (`Request.modalities`, decoded
  into `Response.content`), and
- a dedicated media request (`LlmCall.Media.Request` -> `LlmCall.Media.Response`), which may be
  synchronous or a long-running operation.

The reason for two entry points is that dedicated image/video endpoints have no
`messages`, `system`, or `tools`; flattening a completion request into
`{prompt, n, size}` would be a hidden convention.

### 23.1 Canonical additions

`%LlmCall.Content.Video{}` mirrors `Content.Image` with a `source` and a
`media_type`.

`%LlmCall.Media.Request{}` carries `modality` (`:image` or `:video`), `model`,
`prompt`, `references` (nil, or image and video parts), `params` and
`provider_options`. Every `params` key is optional and nil-by-default: `n`, `size`,
`aspect_ratio`, `duration_s`, `seed`, `negative_prompt`.

`%LlmCall.Media.Response{}` carries `assets`, `revised_prompt`, `usage`, `operation`
and `raw`.

`%LlmCall.Operation{}` carries `id`, `status` (`:queued`, `:in_progress`,
`:completed`, `:failed`), `progress`, `result`, `next`, `next_kind` (`:poll` or
`:asset`), `next_media_type`, `error` and `raw`.

`%LlmCall.Media.Capabilities{}` carries `modalities`, `async`, `max_n` (a positive
integer or `:unsupported`), `sizes`, `aspect_ratios`, `durations_s`, `max_references`
(a non-negative integer or `nil`), `seed` and `negative_prompt`.

`LlmCall.Media.Request` has no `stream`, no `system`, and no `tools` field. `prompt` is the
provider's prompt field, not a message list.

`references` are images or videos the generation is conditioned on. Only
JSON-carriable content is allowed: `%Content.Image{}` and `%Content.Video{}` with
`{:url, _}`, `{:base64, _}`, or string sources. Anything else is a validation
error. A codec that would need a multipart upload rejects `references`.

`Content.Audio` does not exist. Audio is not in scope; adding a type no codec can
fill would be dead weight ([§10.2](#102-canonical-type-evolution)).

### 23.2 Completion-side media output

`Request.modalities` (default `[:text]`) is what the caller will accept:

- an empty list, duplicates, or a value outside `:text | :image | :video` is a
  validation error;
- Gemini GenerateContent maps it to `generationConfig.responseModalities`
  (upcased), omitting the field for the default `[:text]`;
- Gemini GenerateContent with `:video`, and OpenAI Chat or Anthropic Messages
  with `:image` or `:video`, are validation errors;
- **`stream: true` with `:image` or `:video` in `modalities` is a validation
  error.** Progressive media streaming would need a new delta type and touches the
  assembler and every codec; it is out of scope. A caller that wants images calls
  without streaming.
- `Capabilities.modalities` declares the supported set per codec (default
  `[:text]`), so a caller can check before encoding.
- Decoding does not change: generated media arrive as `%Content.Image{}` or
  `%Content.Video{}` parts in `Response.content`.

### 23.3 Media validation and capabilities

`validate_request/2` is a `LlmCall.Media.Codec` callback, implemented per codec. It must
consult `capabilities/2` so that a knob outside the declared surface is a
`:validation` error before anything is sent.

List-valued capability fields enumerate accepted values:

- `sizes: []` means the codec accepts **no** `size` value;
- `max_n: :unsupported` means the codec accepts **no** `n` value (the provider
  takes one asset per request), while an integer `max_n` accepts `1..max_n`;
- `max_references: nil` means the codec accepts no reference; an integer is the
  number it takes (`2` for a first/last-frame pair, `1` for a first frame);
- a `nil` request knob means "provider default" and is always accepted.

Capabilities are static per codec. There is no model catalog
([§2.2](#22-what-this-is-not)), so a codec declares the union its endpoint
supports; a model-specific limit that a codec cannot know surfaces as a provider
error, not a fabricated local guess.

`params` keys outside the canonical set in §23.1 are validation errors, ignoring
keys whose value is `nil` (a `nil` knob is "provider default", not a request).
A codec rejects a non-nil knob it cannot express. `provider_options` is namespaced
and merged like the completion side; the namespace is declared when the adapter
`use`s `LlmCall.Media.Dialect.Adapter` (`namespaces: [:openai]`), so an unknown key is a
validation error. A key that would replace `model`, `prompt`, `instances`, or
`modality` — or a canonical param such as `size`, `n`, or `duration` — is a
validation error too, which is what keeps a `Config` default from beating an
explicit `params` entry. A protocol's own nested parameter object stays
reachable: `parameters` is not reserved, because
`LlmCall.Config.deep_merge/2` recurses into it, so a native Imagen knob such as
`personGeneration` merges beside the canonical `sampleCount` (but the canonical
keys inside it are reserved).

### 23.4 Operation state machine

One rule governs every operation:

- `next` is always the encoded request the client (or your transport) executes
  next, built by the codec. There is no "encode a poll request from an id" callback.
- `decode_operation/2` receives only the payload and the config. A codec is
  stateless, so every continuation value — a file id, a cursor, a page token —
  must travel inside `next` (path, query, or headers). A protocol whose cursor
  cannot be expressed there is out of scope.
- `next_kind: :poll` -> decode the response body and call `decode_operation/3`.
- `next_kind: :asset` -> the response body is media bytes. The core never touches
  them; the transport gives them to the caller with `next_media_type`.
- `status: :queued | :in_progress` -> `result: nil`, `error: nil`, `next` set,
  `next_kind: :poll`.
- `status: :completed` with `next_kind: :asset` -> `result: %LlmCall.Media.Response{assets: []}`
  (the asset is reachable only through `next`).
- `status: :completed` with `next: nil` -> `result: %LlmCall.Media.Response{assets: [...]}`.
- `status: :completed` with `next_kind: :poll` is **not** produced: a codec that
  knows the asset needs another request says so in the same decode result.
- `status: :failed` -> `error` set, `result: nil`, `next: nil`.
- `decode_submit/2` may return `%LlmCall.Media.Response{assets: [...]}` with
  `operation: nil` when the submit response already carries the finished asset.

`id` may be `nil` on a follow-up step: a codec is stateless, so a poll whose
payload does not repeat the job id (MiniMax's file-retrieve step) cannot supply
it.

The library never polls, sleeps, retries, or downloads beyond the request the
caller asks for. The client loop is:

`generate/3` until the operation is `:in_progress`, `poll/3` until it is `:completed`
with `next_kind: :asset`, then `fetch/2` for the bytes.

`poll/3` executes `op.next` and decodes the body with `decode_operation/2`; an
`:asset` operation is rejected with a pointer at `fetch/2`. `fetch/2` never
follows a redirect: a `3xx` is a `:transport` error with the status, and since
`%LlmCall.Error{}` carries no headers the `Location` is lost. A caller whose
asset URL redirects (CDN, pre-signed link) builds an `%LlmCall.HTTP.Request{}`
for that URL and calls `LlmCall.HTTP.request/2`, which returns the response with
headers. A caller that owns a transport calls `LlmCall.encode_media/3` and
`LlmCall.decode_operation/3` directly instead.

`Operation.raw` follows `capture_raw` (`:response` and `:all`).

### 23.5 `LlmCall.Media.Codec` behaviour and public API

| Callback | Contract |
| --- | --- |
| `info/0` | `%LlmCall.Codec.Info{}` |
| `capabilities(request, config)` | `%LlmCall.Media.Capabilities{}` |
| `validate_request(request, config)` | `:ok` or a `:validation` error |
| `encode_submit(request, config)` | `{:ok, %EncodedRequest{}}` or an error |
| `decode_submit(term, config)` | `{:ok, %LlmCall.Media.Response{}}` or an error |
| `decode_operation(term, config)` | `{:ok, %LlmCall.Operation{}}` or an error, optional |
| `decode_error(term, config)` | `%LlmCall.Error{}`, never an error tuple |

`decode_operation/2` is the only optional callback.

| Entry point | Purpose |
| --- | --- |
| `encode_media/3` | validate and encode a submit |
| `decode_media/3` | decode a submit response |
| `decode_operation/3` | decode a poll or asset payload |
| `validate_media/3` | run the codec's validation only |
| `media_capabilities/3` | the codec's declared surface |

`encode_media/3` delegates to the codec, which validates first. `decode_operation/3`
returns a typed `:validation` error when the codec has no `decode_operation/2`,
exactly like the optional streaming callbacks.

Media codecs reuse `LlmCall.Codec.Info`. `ir_version` stays `1`: adding optional
canonical fields with defaults does not change the contract an existing codec was
written against.

### 23.6 Dialect adapters

The media adapters are **vendored** with the library under
`LlmCall.Media.Dialect.*`: they ship in the `llm_call` application, follow the
same conformance suite as the reference chat adapters, and are not part of the
stable API surface (see `LlmCall.Media`). The media IR they map into is stable;
they are not.

Phase M1, synchronous image:

- `LlmCall.Media.Dialect.OpenAI.Images` — `POST /v1/images/generations`, body
  `{model, prompt, n?, size?}`. `response_format: "b64_json"` is sent only for
  `dall-e-*` models: `gpt-image-1` rejects the key and returns base64 anyway, and
  `provider_options.openai` may override the value. `references`,
  `aspect_ratio`, `duration_s`, `negative_prompt`, and `seed` are validation
  errors. Response `data[]`: `b64_json` -> `{:base64, data}`, `url` -> `{:url, url}`.
  `revised_prompt` is the first non-nil value; the rest stay in `raw`.
- `LlmCall.Media.Dialect.Gemini.Predict` (Imagen) — `POST /v1beta/models/{model}:predict`,
  body `{instances: [{prompt}], parameters: {sampleCount?, aspectRatio?, negativePrompt?}}`.
  `size`, `duration_s`, `seed`, and `references` are validation errors. Native
  `parameters` knobs (`personGeneration`, `safetySetting`, `outputOptions`, ...)
  merge through `provider_options`. Response `predictions[].bytesBase64Encoded`
  plus `mimeType` -> base64 image; a prediction with `raiFilteredReason` and no
  bytes is skipped while another prediction has bytes, and is a `:provider` error
  when none do.

Phase M2, asynchronous video. The M2 codecs target the two video APIs this
project actually uses; Sora and Veo are not implemented.

- `LlmCall.Media.Dialect.Seedance.Video` (BytePlus ModelArk) — submit
  `POST /api/v3/contents/generations/tasks` with
  `{model, content: [{type: "text", text: prompt}, {type: "image_url",
  image_url: {url}, role}?], ratio?, duration?, seed?}`; `next` is
  `GET /api/v3/contents/generations/tasks/{id}` with `next_kind: :poll`.
  Statuses map as `queued` -> `:queued`, `running` -> `:in_progress`,
  `succeeded` -> `:completed` with
  `%Content.Video{source: {:url, content.video_url}}`, and
  `failed | cancelled | expired` -> `:failed`. `size`, `negative_prompt`, and `n`
  are validation errors; `resolution`, `watermark`, `generate_audio`,
  `camera_fixed`, and `service_tier` are native knobs reached through
  `provider_options`. `references` accepts one or two images: the first is
  `role: "first_frame"` and the second `role: "last_frame"`, because ModelArk
  requires the roles to tell the pair apart. `durations_s` declares the union
  across Seedance models (2-30 s); a model-specific limit is a provider error.
- `LlmCall.Media.Dialect.MiniMax.Video` (Hailuo, `v1`) — submit
  `POST /v1/video_generation` with
  `{model, prompt, duration?, first_frame_image?}` -> `{task_id}`; `next` is
  `GET /v1/query/video_generation?task_id={id}`. On `Success` the query returns
  only a `file_id`, so the operation stays `:in_progress` with `next` =
  `GET /v1/files/retrieve?file_id={id}`, and that payload completes the job with
  `%Content.Video{source: {:url, file.download_url}}`. `Fail` -> `:failed`.
  Statuses `Preparing | Queueing | Processing` -> `:in_progress`. `size`,
  `aspect_ratio`, `seed`, and `negative_prompt` are validation errors;
  `resolution`, `prompt_optimizer`, `fast_pretreatment`, `callback_url`, and
  `extra` are reached through `provider_options`. `references` accepts one image
  (first frame).
- Both codecs treat a provider error envelope as a `:provider` error. MiniMax
  reports errors as HTTP 200 with a non-zero `base_resp.status_code`, so a
  non-zero `base_resp` is an error regardless of the transport status.

### 23.7 Media non-goals

- audio input or output;
- media streaming (partial or progressive assets), including
  `stream: true` with an image/video modality;
- multipart uploads (image edits/variations from a local file);
- downloading media bytes, polling loops, retries, timeouts, or job persistence;
- cost and model catalogs for media models.

## 24. WebSocket transport

WebSocket is a **transport**, not a completion protocol. `LlmCall.WS` is a
behaviour with five operations:

| Callback | Contract |
| --- | --- |
| `connect(url, headers, opts)` | `{:ok, conn}` or `{:error, reason}` |
| `feed(conn, socket_message)` | `{:ok, frames, conn}` or an error |
| `send_frame(conn, {:text | :binary, binary})` | `{:ok, conn}` or an error |
| `recv(conn, timeout)` | `{:ok, frame, conn}` or an error |
| `close(conn, code, reason)` | `:ok` |

`LlmCall.WS.Mint` implements it with `Mint.WebSocket`: it performs the upgrade,
owns the socket in the calling process, answers pings inside `recv/2` and
`feed/2`, and returns a peer close as `{:close, code, reason}`. `recv/2` is the
blocking form; `feed/2` lets a process that already owns the socket (a connection process)
decode the messages Mint delivers in active mode. Connections are HTTP/1.1;
Mint's HTTP/2 extended CONNECT is not used.

Mint's HTTP proxy options are forwarded (`ws_opts: [proxy: ..., proxy_headers: ...]`),
so `ws://` through a forward proxy and `wss://` through a `CONNECT` tunnel are
transport concerns of the proxy, not of the OpenAI endpoint. SOCKS proxies are
not supported by Mint.

### 24.1 Responses connection

`LlmCall.Dialect.OpenAI.Responses.Connection` is a `GenServer` that owns one
WebSocket connection and multiplexes `response.create` calls. It is a transport
connection, not conversation state: `previous_response_id` and `store` stay with
the caller.

`Connection.start_link(client: client)` opens the socket, `create/3` starts a lane and
returns the stream to reduce.

- Each create names a `stream_id` lane (generated when omitted). Events are
  decoded per lane by the Responses codec and delivered as `StreamEvent`s to the
  `%Connection.Stream{}` returned by `create/3`.
- Events are routed by the `stream_id` the server echoes, which it does for named
  lanes. A server that does not echo it can only be attributed while one lane is
  in flight; `lane_for/2` degrades to that single lane and, once an event has
  proven the echo is missing, a second concurrent `create/3` is a `:validation`
  error instead of a response that would later be unroutable. Back-to-back creates
  are allowed before the first event, because that is how the documented endpoint
  runs parallel conversations and the echo is unknown until then. An event that
  arrives with no route at all disconnects the connection with
  `{:unroutable_event, :stream_id_not_echoed}` rather than delivering it to the
  wrong lane.
- `steer/3` sends `response.steer` with the lane's `previous_response_id` and the
  caller's `input`; a lane that has not received `response.created` is a
  `:validation` error. `cancel/2` sends `response.cancel` with `response_id` and
  ends the lane. Neither event carries `stream_id`: the provider routes them by
  response id.
- `store` and `previous_response_id` stay in the request's `provider_options`;
  the connection does not model server-side conversation state.
- `response_id/2` returns the provider id from `response.created`, so a caller can
  use it as `previous_response_id`. Finished lanes keep the last 32 ids.
- The connection reconnects before the 60-minute limit (`:max_age_ms`, default 55
  minutes) and on an unexpected close, with exponential backoff
  (`:retry_delay_ms` 5s, `:max_retry_delay_ms` 60s) and a bounded budget
  (`:max_reconnect_attempts`, default 5; `:infinity` for unbounded retries).
  A failed reconnect does **not** stop the connection process: it becomes `:disconnected`,
  `create/3` returns a `:transport` error, and `reconnect/1` retries on demand.
- An in-flight response cannot be resumed: its subscriber receives a
  `:transport` error. Continuing a conversation is the caller's decision.
- The URL is built from the client's `base_url` plus the Responses path, with
  `http`/`https` mapped to `ws`/`wss`; Azure's `/openai` base path is preserved.
  The provider's `query:` parameters apply here too, merged over any query
  already present in `base_url`, so a vendor that keys on a URL parameter
  (`GroupId`, `api-version`) still gets it on the handshake.

Scope is the Responses protocol. There is no realtime audio session, audio
format handling, VAD, or WebRTC in 0.1.

## 25. Boundary with catalog, routing and evaluation layers

A full LLM client such as ReqLLM grows a catalog, provider registry, execution
metadata, evaluation, rerank, embeddings, pricing and gateway contracts. Those
are real needs, but they are a different layer. `LlmCall` deliberately stops at
the wire boundary; this section records the split so the core does not drift.

### 25.1 What belongs here

- Canonical wire IR: request, messages, content, tool data, response, stream
  events, usage tokens, errors.
- Dialect codecs and their capability declarations (protocol-level, not
  model-level).
- One-call HTTP/SSE and Responses WebSocket transports, with reconnect for the
  WebSocket connection.
- Provider declaration modules (`use LlmCall.Provider`): origin, auth shape,
  codec names, and transport defaults.
- `provider_options` as a namespaced, documented escape hatch for native fields.

### 25.2 What belongs above

- Model catalog, model IDs, limits, modalities per model, pricing and cost
  estimates.
- Routing by execution metadata, gateway contracts, fallback between providers,
  retries/backoff policy and rate limiting.
- Evaluation, rerank and embedding orchestration: each is a separate protocol
  family with its own endpoint and response shape, not a field on `Request`.
- Subscription OAuth, Claude Code version management and other product-specific
  auth flows; the key/header is supplied by the caller.
- Telemetry, tracing, budgets and approval policies.

### 25.3 Rules that follow

1. **A new operation is a new IR + codec.** `Media` is the precedent: separate
   request, response, capabilities and codec behaviour. Evaluation, rerank and
   embeddings would follow the same shape instead of growing `Request`.
2. **Provider-specific does not mean catalog.** A native field such as an access
   program or a thought-summary toggle stays in `provider_options`; it does not
   become a model registry.
3. **Capabilities are protocol-level.** `Capabilities` answers "can this wire
   format express it", not "does this model support it". Model limits surface as
   provider errors; a caller that needs model selection consults its own catalog.
4. **Transport metadata stays at the boundary.** Response headers, `Retry-After`
   and provider-reported cost are wire data. `Error.retry_after_ms` exposes the
   retry hint; the core never computes a catalog estimate or applies a retry
   policy. Provider-reported cost stays in `raw` (use `capture_raw: :response`)
   or in the upper layer; the canonical `Usage` remains token-only.
5. **Dynamic headers are call options.** `complete/3`, `stream/3`, `generate/3`
   and `poll/3` accept `headers:`; the precedence is client headers, then call
   headers, then codec headers. A call header can override a provider default
   (gateway routing, a Claude Code version, a beta flag); a protocol header
   emitted by the codec still wins. Authentication remains caller-supplied; a
   call header is an explicit override, not a policy.
6. **Routing uses public metadata.** An external router can read
   `Codec.Info`, `Capabilities` and `Provider.__provider__/0`; it does not need a
   registry in the core.
7. **No silent precedence.** When native options interact (for example a
   structured-output request that disables thought summaries), the codec must
   either validate the conflict or document the winning rule; it must not drop
   the loser silently.
