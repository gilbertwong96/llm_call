# LlmCall Design

Status: draft for implementation
Date: 2026-11-12
Project: `llm_call`
Module namespace: `LlmCall`

## 1. Summary

`LlmCall` is a **wire-protocol codec** for LLM APIs, and the ecosystem that
writes adapters for it.

The library ships the canonical IR, the codec behaviours, the conformance
suites, three **reference adapters** — the dialect families the IR is written
against — and a set of **vendored media adapters**. Provider coverage is still
not a goal: the IR's value comes from the breadth of knowledge behind it, not
from the breadth of shipped code. A vendored adapter tracks its provider's API;
the IR it maps into is the stable surface.

`LlmCall` turns a provider-neutral request into the request body, path, and
protocol headers a provider expects, and turns provider response terms into a
provider-neutral response. It deliberately does **not** own HTTP, authentication,
model discovery, tool execution, approvals, retries, or an agent loop.

The core idea:

```text
canonical request
      |
      v
LlmCall.Codec.encode_request/2
      |
      v
transport-neutral encoded request
      |
      v
caller's HTTP transport (Req, Finch, Tesla, ...)
      |
      v
provider response term
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

- an HTTP client
- an SSE/WebSocket parser
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

### 2.3 Relationship to `tool_call`

`LlmCall` does not depend on the `tool_call` project.

The tool concepts in `LlmCall` are wire data only:

- `LlmCall.ToolSpec`: what the model may call
- `LlmCall.ToolCall`: what the model asked to call
- `LlmCall.ToolResult`: the result of a call, ready to send back to the model

A `tool_call` adapter can be a separate package:

```text
tool_call  ---->  llm_call_tool_call  ---->  llm_call
```

or an optional module in the application:

```elixir
specs = LlmCall.ToolCall.from_describe(ToolCall.describe(MyApp.Tools))
```

The adapter converts `ToolCall` IR/schemas into `LlmCall.ToolSpec` values, and
converts returned `LlmCall.ToolCall` values into calls that `ToolCall.run/3`
can execute.

Neither project should depend on the other in its core.

### 2.4 Relationship to LangChain and ReqLLM

| Project          | Focus                                                                    |
|------------------|--------------------------------------------------------------------------|
| LangChain Elixir | Chains, conversation flow, tool execution, callbacks                     |
| ReqLLM           | Complete LLM client with provider transports, registry, streaming, tools |
| `LlmCall`        | Protocol codec and canonical wire IR                                     |

`LlmCall` can be used underneath those systems. It should not grow into another
full client: HTTP, auth, model metadata, and tool execution belong elsewhere.

## 3. Goals

- Provide a small, explicit canonical wire IR.
- Support multiple native protocol families with independent codecs.
- Preserve provider-specific data through raw/escape-hatch fields.
- Keep the core dependency-free (Elixir standard library only).
- Keep transport, auth, model registry, and tool execution out of the core.
- Let applications plug in any tool-call framework.
- Make protocol adapters testable with fixtures, without network access.
- Make capability differences explicit instead of silently dropping fields.
- Keep OpenAI Chat Completions and OpenAI Responses as distinct protocols.

## 4. Non-goals

The core must not contain:

- HTTP request execution
- SSE or WebSocket parsing
- API key storage or OAuth/AWS signing
- model registry or capability database
- retry/backoff/rate-limit policy
- tool execution or callbacks
- approval, audit, or timeout policies
- conversation persistence or server-side state management
- prompt templates, chains, memory, or agent loops
- a JSON encoder dependency

The core may define the **data** needed by those layers, but not implement the
behavior.

## 5. Design principles

1. **Protocol, not provider.** A protocol codec describes a wire format.
   A provider is an endpoint plus authentication plus model availability.
2. **Canonical does not mean lossless.** Canonicalize common concepts; keep
   unknown/provider-specific data in `raw` or `provider_options`.
3. **No silent drops.** If a canonical field cannot be represented by a
   protocol, fail with a protocol/capability error or require an explicit
   provider option.
4. **Terms, not JSON strings.** Codecs return JSON-compatible Elixir terms.
   The transport owns JSON encoding.
5. **No hidden state.** Streaming and continuation state are explicit.
6. **Tool execution is outside.** Tool calls are data; running them is the
   application's job.
7. **Small core, optional adapters.** HTTP and tool integrations live in
   separate packages.
8. **No `term()` in canonical public fields.** Canonical fields use explicit
   unions/structs. `term()` is reserved for genuinely opaque adapter state (for
   example, a protocol stream state) and transport-decoded input at the
   behaviour boundary.

## 6. Approaches considered

### A. Full LLM client

Include HTTP, auth, model registry, streaming transport, tool callbacks, and
high-level `generate_text`.

Advantages:

- easy first call
- broad functionality in one package

Rejected because it duplicates ReqLLM and expands the maintenance surface
without a clear differentiation.

### B. Pure codec plus optional transport

Core contains canonical IR and protocol codecs. A transport package can use
Req/Finch, or applications can use their own client.

Advantages:

- small dependency surface
- usable from any HTTP stack
- easy fixture testing
- independent of tool frameworks
- allows provider/protocol separation

Chosen approach.

### C. Framework-specific adapters only

Implement only adapters for one agent framework.

Rejected because it duplicates protocol work across frameworks and does not
create a reusable foundation.

## 7. Architecture

```text
                    +----------------------+
                    |   application / agent|
                    +----------+-----------+
                               |
             canonical request / response
                               |
                    +----------v-----------+
                    |       LlmCall        |
                    |  canonical wire IR   |
                    +----------+-----------+
                               |
                    +----------v-----------+
                    |  LlmCall.Protocol.*  |
                    |  encode/decode       |
                    +----------+-----------+
                               |
                  encoded request / events
                               |
                    +----------v-----------+
                    |   caller transport  |
                    | Req / Finch / custom|
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
2. **Protocol codec** — encoding request terms and decoding response/event
   terms.
3. **Capabilities** — explicit protocol/model capability description.
4. **Optional adapters** — transport and tool-framework packages.

## 8. Canonical IR

The names below use the existing project namespace, `LlmCall`.

### 8.0 Single source of truth and raw capture

Normalized fields are the authoritative contract. `raw` is an optional,
immutable provider snapshot, never a second source that callers or codecs may
use to update canonical fields after decoding.

Rules:

- `raw` is `nil` by default.
- Raw capture is controlled by `LlmCall.Config.capture_raw`:
  - `:none` — no raw payloads (default)
  - `:response` — retain the full response payload on `Response.raw`
  - `:all` — also retain provider events on `StreamEvent.raw`
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

```elixir
%LlmCall.Request{
  model: "claude-sonnet-4-5",
  system: [%LlmCall.Content.Text{text: "You are helpful."}],
  messages: [%LlmCall.Message{}],
  tools: [%LlmCall.ToolSpec{}],
  tool_choice: :auto,
  output: :text,
  modalities: [:text],
  reasoning: %LlmCall.Reasoning{effort: :high},
  params: %{
    temperature: 0.2,
    top_p: nil,
    top_k: nil,
    max_tokens: 1024,
    stop: nil,
    seed: nil
  },
  provider_options: %{},
  stream: false
}
```

Fields:

- `model` — provider/model identifier as understood by the selected protocol
  and endpoint.
- `system` — `nil`, a string, or a list of text parts. The codec decides where
  it belongs in the provider request.
- `messages` — user/assistant turns. Tool results are content parts, not a
  mandatory `:tool` role.
- `tools` — optional neutral tool specifications.
- `tool_choice` — `:auto | :none | :required | {:tool, name} | {:allowed, [name]}`.
- `output` — `:text | :json_object | {:json_schema, name, schema, strict?}`. This
  describes the text format only.
- `modalities` — which output modalities the caller accepts, default `[:text]`.
  `[:text, :image]` means a response may contain generated image parts as well as
  text. It is a capability request, not a demand: `[:text, :image]` still allows a
  text-only response. See [Media generation](#23-media-generation-image-and-video).
- `reasoning` — optional `%LlmCall.Reasoning{}`; controls thinking/reasoning
  effort or budget where the protocol supports it. Provider-specific controls
  remain in `reasoning.provider_options`.
- `params` — common sampling/length controls.
- `provider_options` — explicit escape hatch for provider-specific options.
- `stream` — whether the caller wants streaming events.

`provider_options` is intentionally not a catch-all for values that the
canonical layer can represent. It is for features that are genuinely
provider-specific.

### 8.2 Message

```elixir
%LlmCall.Message{
  role: :user | :assistant,
  content: [LlmCall.content_part()]
}
```

System instructions stay in `Request.system`, because provider placement
differs:

- OpenAI Chat: system/developer message
- OpenAI Responses: `instructions`
- Anthropic: top-level `system`
- Gemini: `systemInstruction`
- Bedrock Converse: top-level `system`

Tool results are represented as content parts inside a user message:

```elixir
%LlmCall.Message{
  role: :user,
  content: [
    %LlmCall.ToolResult{
      call_id: "call_1",
      name: "get_weather",
      content: [%LlmCall.Content.Text{text: "Sunny"}],
      is_error: false
    }
  ]
}
```

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

`Raw` is an escape hatch for provider-specific blocks that the codec does not
understand. It must be preserved in canonical responses and rendered back when
possible.

### 8.3.1 Reasoning

Reasoning config is separate from `params` because providers expose different
axes:

```elixir
%LlmCall.Reasoning{
  effort: :none | :minimal | :low | :medium | :high | :xhigh | :max | nil,
  budget_tokens: pos_integer() | nil,
  summary: :none | :auto | :concise | :detailed | nil,
  provider_options: %{}
}
```

- `effort` is a canonical hint, not a guarantee that every provider accepts
  every value. `nil` means the provider/model default.
- `budget_tokens` is for providers that expose an explicit thinking budget.
- `summary` is for providers that expose a separate reasoning-summary control.
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

```elixir
%LlmCall.ToolSpec{
  kind: :function | :builtin,
  name: "get_weather" | nil,
  description: "Get current weather" | nil,
  parameters: %{...} | nil,
  strict: nil,
  provider_options: %{}
}
```

- `parameters` is a JSON Schema object (`map()`), not a JSON string or a
  provider-specific schema struct. `nil` is valid for a built-in tool that has
  no function schema.
- `kind: :function` is the normal function-tool case. `kind: :builtin` is for
  provider-defined tools such as web search, file search, code interpreter, or
  computer use; provider-specific details belong in `provider_options` and are
  only supported by adapters that explicitly implement them.
- No callback, function, approval policy, or execution metadata belongs here.
- `strict` is optional; protocol adapters reject it when unsupported or map it
  to their equivalent.

### 8.5 ToolCall

```elixir
%LlmCall.ToolCall{
  id: "call_1" | nil,
  name: "get_weather",
  arguments: %{"city" => "Oslo"} | nil,
  raw_arguments: ~s({"city":"Oslo"}) | nil,
  arguments_error: nil | {:invalid_json, String.t()},
  index: 0 | nil
}
```

The `arguments` map is the decoded form where decoding is safe. Keep the raw
JSON string because:

- OpenAI Chat and Cohere carry arguments as a JSON string.
- Anthropic, Gemini, and Bedrock commonly carry a decoded object.
- Applications may need to preserve invalid or partial fragments.
- Some frameworks expect the raw string.

`id: nil` is valid because Gemini `functionCall` does not have a call id.

When `raw_arguments` is present, `arguments` is its decoded value. If decoding
fails, `arguments` is `nil` and `arguments_error` explains the failure; the
codec must not silently turn malformed arguments into `%{}`.

### 8.6 ToolResult

```elixir
%LlmCall.ToolResult{
  call_id: "call_1" | nil,
  name: "get_weather",
  content: [LlmCall.ContentPart.t()] | String.t(),
  is_error: false
}
```

Adapters validate required identifiers:

- OpenAI Chat requires `call_id`.
- OpenAI Responses requires `call_id`.
- Anthropic uses `tool_use_id`.
- Gemini uses `name` and no id.
- Bedrock uses `toolUseId`.
- Cohere uses `tool_call_id`.

### 8.7 Response

```elixir
%LlmCall.Response{
  id: "msg_123",
  model: "claude-sonnet-4-5",
  content: [LlmCall.ContentPart.t()],
  stop_reason: :end_turn
               | :tool_calls
               | :max_tokens
               | :stop_sequence
               | :content_filter
               | :error
               | :unknown,
  usage: %LlmCall.Usage{},
  raw: nil
}
```

`content` is a list of content parts, not provider-specific `choices` or output
items. `raw` is a `map() | nil` provider snapshot, populated only when
`Config.capture_raw` is `:response` or `:all`.

`Response.raw` must not be treated as a second response model. Use
`content`/`usage`/`stop_reason`; use raw only when provider-specific information
was not represented canonically.

Convenience helpers can be added without changing the IR:

```elixir
LlmCall.Response.text(response)
LlmCall.Response.tool_calls(response)
```

### 8.8 Usage

```elixir
%LlmCall.Usage{
  input_tokens: 123,
  output_tokens: 45,
  total_tokens: 168,
  cache_read_tokens: 0,
  cache_write_tokens: 0,
  reasoning_tokens: nil
}
```

Pricing and cost calculation are outside the core.

Cost is not a wire field. It depends on provider, model, region, cache
read/write pricing, batch/tier discounts, and reasoning-token pricing. The
canonical `Usage` records the token dimensions needed by an upper layer, but
`LlmCall` does not store price tables or computed cost. If an application needs
cost tracking, use an optional `llm_call_cost` package or its own model-pricing
layer. Provider-specific billing fields, if returned, belong in `raw` or a
provider-specific extension.

### 8.9 Error

```elixir
%LlmCall.Error{
  kind: :protocol | :validation | :invalid_response | :provider,
  message: "...",
  code: "invalid_request_error" | nil,
  status: 400 | nil,
  retryable?: false,
  raw: map() | nil
}
```

`code` is the provider's machine-readable code as a string (OpenAI's `code`,
Anthropic's error type, Google's status such as `"RESOURCE_EXHAUSTED"`,
MiniMax's numeric code stringified). `status` is the HTTP status, and **only the
transport sets it**: a codec never sees the response status, so it always leaves
it `nil`.

HTTP-level transport failures are transport errors. Provider error envelopes
decoded by a protocol codec become `LlmCall.Error`.

### 8.10 Capabilities

Capabilities are explicit and per protocol/config. They are **protocol-level**:
`capabilities/2` takes the request for signature symmetry but does not inspect the
model; a model-specific limit surfaces as a provider error rather than a
fabricated local guess.

```elixir
%LlmCall.Capabilities{
  tools: true,
  parallel_tool_calls: false,
  tool_choice: true,
  structured_output: :json_schema,
  modalities: [:text],
  image_input: true,
  file_input: false,
  reasoning: %LlmCall.ReasoningCapabilities{
    supported: true,
    efforts: [:low, :medium, :high],
    default_effort: :medium,
    budget_tokens: false,
    adaptive: true,
    summary: [:auto, :concise, :detailed]
  },
  streaming_tool_calls: true,
  prompt_cache: true,
  stateful: false,
  streaming: true
}
```

`LlmCall.Codec.validate_request/2` can reject unsupported combinations
before a transport sends anything. No silent field dropping.

### 8.11 Canonical type specifications

The public structs should expose the following types. These are the types an
implementation should write into the canonical modules; they are not optional
documentation.

```elixir
defmodule LlmCall do
  @type model :: String.t()
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
end

defmodule LlmCall.StreamState do
  @opaque t :: %__MODULE__{codec: module(), data: term()}
  defstruct [:codec, :data]

  @spec new(module(), term()) :: t()
  def new(codec, data), do: %__MODULE__{codec: codec, data: data}

  @spec codec(t()) :: module()
  def codec(%__MODULE__{codec: codec}), do: codec

  @spec data(t()) :: term()
  def data(%__MODULE__{data: data}), do: data
end

defmodule LlmCall.Content do
  @type source ::
          String.t()
          | {:url, String.t()}
          | {:base64, String.t()}
          | {:file_id, String.t()}

  @type part ::
          %LlmCall.Content.Text{text: String.t()}
          | %LlmCall.Content.Image{source: source(), media_type: String.t() | nil}
          | %LlmCall.Content.File{
              source: source(),
              media_type: String.t() | nil,
              filename: String.t() | nil
            }
          | %LlmCall.Content.Video{source: source(), media_type: String.t() | nil}
          | %LlmCall.ToolCall{}
          | %LlmCall.ToolResult{}
          | %LlmCall.Content.Thinking{text: String.t(), signature: String.t() | nil}
          | %LlmCall.Content.Raw{type: String.t() | nil, data: map()}
end

defmodule LlmCall.Content.Text do
  @type t :: %__MODULE__{text: String.t()}
  defstruct [:text]
end

defmodule LlmCall.Content.Image do
  @type t :: %__MODULE__{
          source: LlmCall.Content.source(),
          media_type: String.t() | nil
        }
  defstruct [:source, :media_type]
end

defmodule LlmCall.Content.File do
  @type t :: %__MODULE__{
          source: LlmCall.Content.source(),
          media_type: String.t() | nil,
          filename: String.t() | nil
        }
  defstruct [:source, :media_type, :filename]
end

defmodule LlmCall.Content.Thinking do
  @type t :: %__MODULE__{text: String.t(), signature: String.t() | nil}
  defstruct [:text, :signature]
end

defmodule LlmCall.Content.Raw do
  @type t :: %__MODULE__{type: String.t() | nil, data: map()}
  defstruct [:type, :data]
end

defmodule LlmCall.Request do
  @type system :: nil | String.t() | [LlmCall.Content.Text.t()]
  @type tool_choice ::
          :auto
          | :none
          | :required
          | {:tool, String.t()}
          | {:allowed, [String.t()]}
  @type output ::
          :text
          | :json_object
          | {:json_schema, String.t(), map(), boolean() | nil}
  @type params :: %{optional(atom()) => nil | boolean() | number() | String.t() | [String.t()]}

  @type t :: %__MODULE__{
          model: String.t(),
          system: system(),
          messages: [LlmCall.Message.t()],
          tools: [LlmCall.ToolSpec.t()],
          tool_choice: tool_choice(),
          output: output(),
          modalities: [LlmCall.modality()],
          reasoning: LlmCall.Reasoning.t() | nil,
          params: params(),
          provider_options: map(),
          stream: boolean()
        }
end

defmodule LlmCall.Message do
  @type role :: :user | :assistant
  @type t :: %__MODULE__{role: role(), content: [LlmCall.Content.part()]}
end

defmodule LlmCall.Reasoning do
  @type level ::
          :none | :minimal | :low | :medium | :high | :xhigh | :max
  @type effort :: level() | nil
  @type summary :: :none | :auto | :concise | :detailed | nil
  @type t :: %__MODULE__{
          effort: effort(),
          budget_tokens: pos_integer() | nil,
          summary: summary(),
          provider_options: map()
        }
end

defmodule LlmCall.ReasoningCapabilities do
  @type t :: %__MODULE__{
          supported: boolean(),
          efforts: [LlmCall.Reasoning.level()],
          default_effort: LlmCall.Reasoning.level() | nil,
          budget_tokens: boolean(),
          adaptive: boolean(),
          summary: [:none | :auto | :concise | :detailed]
        }
end

defmodule LlmCall.ToolSpec do
  @type kind :: :function | :builtin
  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t() | nil,
          description: String.t() | nil,
          parameters: map() | nil,
          strict: boolean() | nil,
          provider_options: map()
        }
end

defmodule LlmCall.ToolCall do
  @type arguments :: map() | nil
  @type arguments_error :: nil | {:invalid_json, String.t()}
  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          arguments: arguments(),
          raw_arguments: String.t() | nil,
          arguments_error: arguments_error(),
          index: non_neg_integer() | nil
        }
end

defmodule LlmCall.ToolResult do
  @type content :: [LlmCall.Content.Text.t()] | String.t()
  @type t :: %__MODULE__{
          call_id: String.t() | nil,
          name: String.t() | nil,
          content: content(),
          is_error: boolean()
        }
end

defmodule LlmCall.Response do
  @type t :: %__MODULE__{
          id: String.t() | nil,
          model: String.t() | nil,
          content: [LlmCall.Content.part()],
          stop_reason: LlmCall.stop_reason(),
          usage: LlmCall.Usage.t() | nil,
          raw: map() | nil
        }
end

defmodule LlmCall.Usage do
  @type tokens :: non_neg_integer() | nil
  @type t :: %__MODULE__{
          input_tokens: tokens(),
          output_tokens: tokens(),
          total_tokens: tokens(),
          cache_read_tokens: tokens(),
          cache_write_tokens: tokens(),
          reasoning_tokens: tokens()
        }
end

defmodule LlmCall.Error do
  @type t :: %__MODULE__{
          kind: :protocol | :validation | :invalid_response | :provider,
          message: String.t(),
          code: String.t() | nil,
          status: non_neg_integer() | nil,
          retryable?: boolean(),
          raw: map() | nil
        }
end

defmodule LlmCall.Config do
  @type t :: %__MODULE__{
          default_provider_options: map(),
          capture_raw: LlmCall.capture_raw()
        }
end

defmodule LlmCall.Capabilities do
  @type t :: %__MODULE__{
          tools: boolean(),
          parallel_tool_calls: boolean(),
          tool_choice: boolean(),
          structured_output: :none | :json_object | :json_schema,
          modalities: [LlmCall.modality()],
          image_input: boolean(),
          file_input: boolean(),
          reasoning: LlmCall.ReasoningCapabilities.t() | nil,
          streaming_tool_calls: boolean(),
          prompt_cache: boolean(),
          stateful: boolean(),
          streaming: boolean()
        }
end

defmodule LlmCall.EncodedRequest do
  @type t :: %__MODULE__{
          method: :post | :get,
          path: String.t(),
          query: %{optional(String.t()) => String.t() | integer() | boolean()},
          headers: [{String.t(), String.t()}],
          body: map()
        }
end
```

`LlmCall.StreamEvent` and its `StreamDelta` types are specified in
[Streaming](#12-streaming).

## 9. OpenAI Chat Completions vs Responses

These are separate protocol adapters, not one endpoint toggle.

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
LlmCall.Protocol.OpenAI.Chat
LlmCall.Protocol.OpenAI.Responses
```

The canonical IR can be shared, but the response/event/state mapping must be
independent.

OpenAI Responses state is deliberately provider-specific. `previous_response_id`
and `store` live in `Request.provider_options` (for example under an `:openai`
key) and are interpreted by the Responses adapter; `LlmCall` does not model
server-side conversation state. The canonical `Response.id` remains available
for the caller to continue the conversation.

## 10. Codec contract

```elixir
defmodule LlmCall.Codec.Info do
  @type t :: %__MODULE__{
          name: atom(),
          protocol: atom(),
          version: String.t() | nil,
          ir_version: pos_integer()
        }
  defstruct [:name, :protocol, :version, :ir_version]
end
```

`name` identifies the codec instance and `protocol` the wire family; they are
equal for every codec today (one codec per family) and differ only when one
module serves a family with variants. `version` is the wire version the codec
targets — Anthropic's `2023-06-01`, Gemini's `v1beta`, Seedance's `v3` — and
`nil` when the protocol has no versioned surface (OpenAI Chat and Images).
`ir_version` is the canonical IR contract the codec was written against.

```elixir
defmodule LlmCall.Codec do
  @callback info() :: LlmCall.Codec.Info.t()

  @callback encode_request(
              LlmCall.Request.t(),
              LlmCall.Config.t()
            ) ::
              {:ok, LlmCall.EncodedRequest.t()}
              | {:error, LlmCall.Error.t()}

  @callback decode_response(
              LlmCall.wire_value(),
              LlmCall.Config.t()
            ) ::
              {:ok, LlmCall.Response.t()}
              | {:error, LlmCall.Error.t()}

  @callback decode_stream_event(
              LlmCall.wire_value(),
              LlmCall.Config.t(),
              LlmCall.StreamState.t()
            ) ::
              {:ok, [LlmCall.StreamEvent.t()], LlmCall.StreamState.t()}
              | {:done, LlmCall.StreamState.t()}
              | {:error, LlmCall.Error.t()}

  @callback decode_error(
              LlmCall.wire_value(),
              LlmCall.Config.t()
            ) :: LlmCall.Error.t()

  @callback validate_request(
              LlmCall.Request.t(),
              LlmCall.Config.t()
            ) :: :ok | {:error, LlmCall.Error.t()}

  @callback init_stream(
              LlmCall.Request.t(),
              LlmCall.Config.t()
            ) :: {:ok, LlmCall.StreamState.t()} | {:error, LlmCall.Error.t()}

  @callback finish_stream(
              LlmCall.StreamState.t(),
              LlmCall.Config.t()
            ) ::
              {:ok, [LlmCall.StreamEvent.t()], LlmCall.StreamState.t()}
              | {:error, LlmCall.Error.t()}

  @callback capabilities(
              LlmCall.Request.t(),
              LlmCall.Config.t()
            ) :: LlmCall.Capabilities.t()

  @optional_callbacks
    init_stream: 2,
    decode_stream_event: 3,
    finish_stream: 2
end
```

`LlmCall.Codec` is a behaviour. `LlmCall.Protocol.*` modules are concrete
wire-protocol adapters that implement it. `Protocol` here is the domain
namespace for wire protocols, not Elixir's `defprotocol`.

`info/0` lets a codec declare its protocol name, wire version, and the canonical
IR version it implements. `init_stream/2`, `decode_stream_event/3`, and
`finish_stream/2` are optional so a non-streaming codec does not have to
implement dummy callbacks. When streaming is unavailable, the public API returns
a typed `LlmCall.Error` rather than raising.

Streaming state is never exposed as a bare `term()`. It is wrapped in opaquely
typed `LlmCall.StreamState`:

```elixir
%LlmCall.StreamState{codec: MyCodec, data: codec_private_state}
```

The public API checks `StreamState.codec(state) == selected_codec` before
delegating, so passing an Anthropic state to the OpenAI codec is a typed error.
Codec implementations use `StreamState.data/1` and `StreamState.new/2`; the
`data` remains deliberately opaque.

`Config` contains codec defaults and capture policy, not the canonical model
selection:

```elixir
%LlmCall.Config{
  default_provider_options: %{},
  capture_raw: :none
}
```

`default_provider_options` is merged before `Request.provider_options`; the
request value wins per key. `Request.model` is the only model selection.
`Config` does not contain credentials or a base URL.

```elixir
@type capture_raw :: :none | :response | :all
```

### 10.1 Codec discovery and extension

Codec selection is explicit:

```elixir
LlmCall.encode(LlmCall.Protocol.OpenAI.Chat, request, config)
```

There is no provider or codec registry in the core. A higher-level client may
map provider/model names to codec modules, but `LlmCall` does not. This keeps a
new protocol adapter independent of model catalogs and authentication.

Adding a new codec should require only:

1. A module implementing `LlmCall.Codec`.
2. Protocol-specific request/response/stream fixtures.
3. Codec metadata via `info/0`.
4. Capability declarations for the models/endpoints the codec supports.

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
lib/llm_call/codec_conformance.ex    # LlmCall.Codec.Conformance
lib/llm_call/media_conformance.ex    # LlmCall.MediaConformance
```

They are test support, not runtime dependencies: they `import
ExUnit.Assertions` (part of every Elixir installation) and are meant to be
called from a test.

What they check today:

- `info/0` metadata
- streaming-callback presence matching `capabilities.streaming` (and
  `decode_operation/2` matching `LlmCall.Media.Capabilities.async`)
- encoded path/method/body/query shape, and credential-free headers
- `capture_raw` on `Response.raw` and `LlmCall.Media.Response.raw` (core's unit tests also
  cover `Operation.raw`; the published suite does not)
- stream roundtrip and stream-state ownership (the request is passed in, so an
  out-of-tree codec is checkable)
- `Operation` state-machine invariants
- capability declarations matching validation, in both directions, for **media**
  codecs
- rejection of a request with a field the codec cannot express
  (`assert_rejects/3`) — the "no silent drops" promise as a test

Not yet checked, tracked as a follow-up (C1): response and error decoding,
streaming event order, tool-call fragment assembly, usage/stop-reason mapping,
and a chat-side capability↔validation check. An adapter can verify its shapes,
capture policy, stream plumbing, capabilities, rejection of unsupported fields,
and operation states — not its decoders.

## 11. Encoded request boundary

```elixir
%LlmCall.EncodedRequest{
  method: :post,
  path: "/v1/chat/completions",
  query: %{},
  headers: [{"anthropic-version", "2023-06-01"}],
  body: %{}
}
```

- `path`, `query`, `headers`, and `body` are protocol-level facts.
- `body` is a JSON-compatible term, not an encoded JSON string.
- Headers may include required protocol headers.
- Headers must not include credentials; authentication is added by the
  transport.
- The transport prepends the base URL and performs JSON encoding.

Example caller:

```elixir
{:ok, encoded} =
  LlmCall.encode(LlmCall.Protocol.OpenAI.Chat, request, config)

body = JSON.encode!(encoded.body)

Req.post!(
  base_url <> encoded.path,
  headers: auth_headers ++ encoded.headers,
  body: body
)
```

## 12. Streaming

The core defines normalized events; it does not parse SSE.

```elixir
defmodule LlmCall.StreamEvent do
  @type type ::
          :message_start
          | :content_start
          | :text_delta
          | :tool_call_start
          | :tool_call_delta
          | :tool_call_stop
          | :thinking_delta
          | :content_stop
          | :message_delta
          | :message_stop
          | :error

  @type index :: non_neg_integer() | nil

  @type delta ::
          nil
          | %LlmCall.StreamDelta.Text{text: String.t()}
          | %LlmCall.StreamDelta.ToolCall{
              id: String.t() | nil,
              name: String.t() | nil,
              arguments: String.t() | nil,
              index: index()
            }
          | %LlmCall.StreamDelta.Thinking{
              text: String.t(),
              signature: String.t() | nil
            }
          | %LlmCall.StreamDelta.MessageDelta{
              stop_reason: LlmCall.stop_reason() | nil,
              usage: LlmCall.Usage.t() | nil
            }
          | %LlmCall.StreamDelta.Raw{data: map()}

  @type raw :: map() | nil

  @type t :: %__MODULE__{
          type: type(),
          index: index(),
          delta: delta(),
          raw: raw()
        }

  defstruct [:type, :index, :delta, :raw]
end
```

The delta modules are small typed structs:

```elixir
defmodule LlmCall.StreamDelta.Text do
  @type t :: %__MODULE__{text: String.t()}
  defstruct [:text]
end

defmodule LlmCall.StreamDelta.ToolCall do
  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          arguments: String.t() | nil,
          index: non_neg_integer() | nil
        }
  defstruct [:id, :name, :arguments, :index]
end

defmodule LlmCall.StreamDelta.Thinking do
  @type t :: %__MODULE__{
          text: String.t(),
          signature: String.t() | nil
        }
  defstruct [:text, :signature]
end

defmodule LlmCall.StreamDelta.MessageDelta do
  @type t :: %__MODULE__{
          stop_reason: LlmCall.stop_reason() | nil,
          usage: LlmCall.Usage.t() | nil
        }
  defstruct [:stop_reason, :usage]
end

defmodule LlmCall.StreamDelta.Raw do
  @type t :: %__MODULE__{data: map()}
  defstruct [:data]
end
```

`delta` is a closed union of these canonical delta structs. It must not be
`term()`, and each delta type must be usable without pattern-matching raw
provider JSON.

`raw` is provider-specific but still typed as a JSON object (`map()`) or
`nil`. It is populated only when `Config.capture_raw == :all`, so normal
streaming does not retain a second full event per chunk. If a provider sends a
non-object sentinel, the transport/codec should normalize it to
`{:done, state}` or wrap it in a map; it should not leak an arbitrary term into
the public type.

### 12.1 Streaming tool-call assembly

The wire layer can emit tool-call fragments before the model has finished its
output. A separate, pure `LlmCall.StreamAssembler` turns those fragments into
complete `LlmCall.ToolCall` values.

```elixir
defmodule LlmCall.StreamAssembler do
  @type decoder :: (String.t() -> {:ok, map()} | {:error, String.t()}) | nil

  @opaque t :: %__MODULE__{
            json_decoder: decoder(),
            calls: map()
          }

  defstruct json_decoder: nil, calls: %{}

  @spec new(keyword()) :: t()
  def new(opts \\ [])

  @spec feed(t(), LlmCall.StreamEvent.t()) ::
          {:ok, t(), [LlmCall.ToolCall.t()]}

  @spec finish(t()) :: {:ok, t(), [LlmCall.ToolCall.t()]}
end
```

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

The core does not depend on a JSON codec. `new/1` accepts an optional
`json_decoder`:

```elixir
StreamAssembler.new(json_decoder: &JSON.decode/1)
```

`json_decoder` receives the accumulated argument string and returns
`{:ok, map()} | {:error, String.t()}`. If no decoder is provided, the assembler
returns the complete `ToolCall` with `arguments: nil` and an
`arguments_error` explaining that decoding was unavailable. If decoding fails,
the same error field is populated and `raw_arguments` is preserved.

Provider timing differs:

| Protocol | Tool-call completion signal | Early execution before message end |
| --- | --- | --- |
| OpenAI Chat Completions | `finish_reason: "tool_calls"` / final chunk | normally at message end |
| OpenAI Responses | `response.output_item.done` for the function call | often before response end |
| Anthropic Messages | `content_block_stop` for the tool block | yes, when the block stops |
| Gemini GenerateContent | complete `functionCall` part | yes |
| Bedrock Converse | tool-use block stop / message stop | provider-dependent |
| Cohere Chat | final tool-call chunk / finish reason | usually at response end |

Early execution is an application decision. `LlmCall` only exposes complete
calls; it does not run them or insert results into an active response.

Transport responsibilities:

- parse SSE framing
- decode JSON payloads
- detect provider stream terminators such as `[DONE]`
- pass decoded terms to `decode_stream_event/3`

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

### `tool_call` adapter

```elixir
specs =
  ToolCall.describe(MyApp.Tools)
  |> Enum.map(&LlmCall.ToolCall.from_describe/1)

request = %LlmCall.Request{
  model: "...",
  messages: messages,
  tools: specs
}
```

After decoding:

```elixir
for call <- LlmCall.Response.tool_calls(response) do
  ToolCall.run(MyApp.Tools, call.name, call.arguments)
end
```

The adapter should live in a separate package or an optional module:

```text
llm_call_tool_call
```

Dependency direction:

```text
llm_call              no tool_call dependency
tool_call             no llm_call dependency
llm_call_tool_call    depends on both
```

### Other frameworks

Any framework can map its own tool definition to `LlmCall.ToolSpec` and consume
`LlmCall.ToolCall` / `LlmCall.ToolResult`. No framework is privileged.

### MCP

MCP is a tool/resource transport, not an LLM completion protocol. An MCP tool
catalog can be converted into `LlmCall.ToolSpec` values outside the core.

## 14. Protocol adapters

### Phase 1

- `LlmCall.Protocol.OpenAI.Chat`
- `LlmCall.Protocol.Anthropic.Messages`
- `LlmCall.Protocol.Gemini.GenerateContent`

These cover the most common request/response shapes and validate the canonical
IR.

### Vendored media adapters

These ship in this repository under `LlmCall.Media.Protocol.*`. They are not
part of the stable API surface: a provider API change can force an adapter change
in a minor release, which is why they are named separately from the reference
adapters. See `LlmCall.Media` for the contract.

- `LlmCall.Media.Protocol.OpenAI.Images`
- `LlmCall.Media.Protocol.Gemini.Predict` (Imagen)
- `LlmCall.Media.Protocol.Seedance.Video`
- `LlmCall.Media.Protocol.MiniMax.Video`

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

The protocol adapter is selected independently from the provider endpoint.

## 15. Module layout

```text
lib/llm_call.ex
lib/llm_call/request.ex
lib/llm_call/response.ex
lib/llm_call/message.ex
lib/llm_call/content.ex
lib/llm_call/tool_spec.ex
lib/llm_call/tool_call.ex
lib/llm_call/tool_result.ex
lib/llm_call/reasoning.ex
lib/llm_call/reasoning_capabilities.ex
lib/llm_call/stream_event.ex
lib/llm_call/stream_state.ex
lib/llm_call/stream_delta.ex
lib/llm_call/stream_assembler.ex
lib/llm_call/usage.ex
lib/llm_call/error.ex
lib/llm_call/capabilities.ex
lib/llm_call/config.ex
lib/llm_call/encoded_request.ex
lib/llm_call/codec.ex
lib/llm_call/codec/info.ex
lib/llm_call/media/codec.ex
lib/llm_call/media/request.ex
lib/llm_call/media/response.ex
lib/llm_call/media/capabilities.ex
lib/llm_call/operation.ex
lib/llm_call/codec_conformance.ex
lib/llm_call/media_conformance.ex
lib/llm_call/protocol/helpers.ex
lib/llm_call/protocol/openai/chat.ex
lib/llm_call/protocol/anthropic/messages.ex
lib/llm_call/protocol/gemini/generate_content.ex
lib/llm_call/media.ex
lib/llm_call/media/protocol/openai/images.ex
lib/llm_call/media/protocol/gemini/predict.ex
lib/llm_call/media/protocol/seedance/video.ex
lib/llm_call/media/protocol/minimax/video.ex
```

The three `protocol/*` modules are **reference adapters**: the dialect families
the IR is written against. The `media/protocol/*` modules are **vendored**
adapters: they ship with the library but are not part of the stable surface.

Optional packages:

```text
llm_call_req          Req/Finch transport
llm_call_cost         optional pricing/cost calculation
llm_call_tool_call    ToolCall adapter
llm_call_langchain    LangChain adapter
```

Test support (core's own suite):

```text
test/support/codecs/      completing and non-conforming codec fakes
test/support/fixtures/    reference-adapter payloads
```

## 16. Public API sketch

```elixir
request = %LlmCall.Request{
  model: "claude-sonnet-4-5",
  system: [%LlmCall.Content.Text{text: "You are helpful."}],
  messages: [
    %LlmCall.Message{
      role: :user,
      content: [%LlmCall.Content.Text{text: "Hello"}]
    }
  ]
}

config = %LlmCall.Config{capture_raw: :none}

{:ok, encoded} =
  LlmCall.encode(LlmCall.Protocol.Anthropic.Messages, request, config)

# transport performs HTTP + JSON

{:ok, response} =
  LlmCall.decode_response(
    LlmCall.Protocol.Anthropic.Messages,
    response_term,
    config
  )
```

Streaming:

```elixir
protocol = LlmCall.Protocol.Anthropic.Messages

{:ok, state} = LlmCall.init_stream(protocol, request, config)

{:ok, events, state} =
  LlmCall.decode_stream_event(protocol, json_event, config, state)

# Optional pure assembler; no tool execution.
assembler = LlmCall.StreamAssembler.new(json_decoder: &JSON.decode/1)

{:ok, assembler, completed_calls} =
  Enum.reduce(events, {:ok, assembler, []}, fn event, {:ok, acc, calls} ->
    {:ok, acc, new_calls} = LlmCall.StreamAssembler.feed(acc, event)
    {:ok, acc, calls ++ new_calls}
  end)
```

The core public API is:

```elixir
LlmCall.encode(protocol, request, config \\ %LlmCall.Config{})
LlmCall.decode_response(protocol, response_term, config \\ %LlmCall.Config{})
LlmCall.init_stream(protocol, request, config \\ %LlmCall.Config{})
LlmCall.decode_stream_event(protocol, event_term, config, state)
LlmCall.finish_stream(protocol, state, config)
LlmCall.StreamAssembler.new(keyword())
LlmCall.StreamAssembler.feed(assembler, event)
LlmCall.StreamAssembler.finish(assembler)
LlmCall.validate_request(protocol, request, config \\ %LlmCall.Config{})
LlmCall.capabilities(protocol, request, config \\ %LlmCall.Config{})
```

`encode` returns `{:ok, %LlmCall.EncodedRequest{}}`; `decode_response`,
`decode_stream_event`, `finish_stream`, `validate_request`, `capabilities`,
`decode_operation`, and the media operations return their documented
success/error tuples; `capabilities` and `media_capabilities` return
`{:ok, struct} | {:error, %LlmCall.Error{}}`.

Dispatch never raises for a module that implements the other behaviour: each
entry checks a behaviour-unique callback (`encode_request/2` for completion,
`encode_submit/2` for media) and returns a `:validation` error. The exception is
`decode_error/3`, whose callback exists in both behaviours.

## 17. Testing

The core test suite must not need a live API.

For each protocol:

1. **Request fixtures**
   - canonical request -> exact JSON-compatible body
   - path/query/headers
   - tool definitions and tool choice
   - system placement
   - multi-modal content

2. **Response fixtures**
   - text response
   - tool call response
   - multiple content blocks
   - usage/stop reason mapping
   - provider error response

3. **Streaming fixtures**
   - text deltas
   - tool call fragments
   - thinking/reasoning deltas
   - final `message_delta` stop reason and usage
   - streaming tool-call start/delta/stop assembly
   - fragmented JSON arguments and malformed arguments
   - multiple tool calls by `index`
   - early completion before `message_stop`
   - terminator handling
   - unknown event preservation
   - `capture_raw: :none/:response/:all`

4. **Capability tests**
   - unsupported request fields are rejected, not silently dropped
   - provider-specific options pass through
   - protocol-level capabilities are checked per codec
   - reasoning effort/budget/summary mapping and unsupported combinations
   - cost is not fabricated from token counts
   - non-streaming codecs reject streaming calls cleanly
   - passing a StreamState to the wrong codec returns a typed error

5. **Round-trip tests**
   - canonical request -> provider term -> expected canonical request shape
   - provider response -> canonical response -> expected content/tool calls

6. **Tool framework adapter tests**
   - `ToolCall` describe -> `ToolSpec`
   - canonical `ToolCall` -> `ToolCall.run` input
   - missing call ids and provider-specific constraints
   - malformed JSON arguments produce `arguments_error`, not an empty map

7. **Codec conformance**
   - `info/0` protocol/version/IR version
   - optional streaming callbacks
   - `finish_stream/2` flushes final usage/stop events
   - shared `LlmCall.Codec.Conformance` fixtures

8. **Media generation tests**
   - image request -> exact body, path, headers
   - synchronous image response -> `LlmCall.Media.Response.assets`
   - submit -> poll -> completed state machine, including an asset-fetch step
   - capability rejection for knobs a codec cannot express
   - `capture_raw` on `LlmCall.Media.Response.raw` and `Operation.raw`
   - a media codec without `decode_operation/2` returns a typed error
   - `Request.modalities` mapping per codec, including the streaming rejection

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

If the following appear in the core project, the design has drifted:

- a `Req` or `Finch` dependency
- a default HTTP client
- API key lookup
- `generate_text` high-level helpers
- a model catalog
- a tool callback or tool runner
- an agent loop
- a prompt template or memory system
- automatic retries or rate limiting
- provider-specific branches in user application code

Those belong in adapters or higher-level packages.

## 20. Open decisions

1. **Core transport:** stay fully transport-free. Recommended: yes.
2. **JSON encoding:** codecs return terms; transport encodes. Recommended: yes.
3. **Tool data in core:** include neutral `ToolSpec`, `ToolCall`, and
   `ToolResult`; no execution. Recommended: yes.
4. **First protocol set:** OpenAI Chat, Anthropic Messages, Gemini
   GenerateContent. Recommended: yes.
5. **OpenAI Responses timing:** an ecosystem package, not a core adapter.
   Recommended: yes.
6. **Stream assembler:** pure helper in core or a separate package. Start in
   core only if it remains protocol-neutral; otherwise split.
7. **SSE parser:** outside core, in the transport package.
8. **Codec discovery:** explicit codec module selection; no core provider or
   codec registry. Recommended: yes.

## 21. Implementation order

1. Define canonical structs and types, including reasoning.
2. Define codec behaviour, encoded request, error, capabilities.
3. Implement OpenAI Chat codec with request/response/stream fixtures.
4. Implement Anthropic Messages codec.
5. Implement Gemini GenerateContent codec.
6. Add generic OpenAI-compatible configuration.
7. Add optional transport package.
8. Add optional `tool_call` adapter.
9. Add the media IR ([§23](#23-media-generation-image-and-video)):
   `Content.Video`, `Request.modalities`, `Capabilities.modalities`,
   `LlmCall.Media.Request`, `LlmCall.Media.Response`, `LlmCall.Operation`, `LlmCall.Media.Capabilities`, the
   `LlmCall.Media.Codec` behaviour, and the public media API.
10. Publish the conformance suites from `lib/`, ban `@moduledoc false`, and
    document the adapter-authoring contract.
11. Add the media adapters under `LlmCall.Media.Protocol.*`: OpenAI Images,
    Gemini Imagen `predict`, Seedance, MiniMax Hailuo.

Adapters beyond the reference and vendored sets are not implementation phases.

The first milestone should be useful without any transport implementation:
a request can be encoded and a fixture response can be decoded in tests.

## 22. Design success criteria

This design is working if:

- A caller can use `LlmCall` without any agent framework.
- A third party can write an adapter, decode against their own fixtures, and
  verify its shapes, capture policy, stream plumbing, capabilities, and operation
  states with the conformance suite — without touching core.
- An adapter outside this repository needs no core release; a vendored one is
  allowed to change with its provider without changing the IR.
- A different tool framework can use `LlmCall` without importing `tool_call`.
- Adding a protocol adapter does not require changing canonical messages.
- Provider-specific features remain accessible through explicit escape hatches.
- The core package has no HTTP, auth, registry, or tool-execution dependency.
- Protocol fixtures are readable and testable without network access.
- A caller can generate images and run video generation jobs without writing
  provider-specific HTTP, and without the core polling or downloading anything.

## 23. Media generation (image and video)

The media **IR** is first-class and stable; media **adapters** are vendored
under `LlmCall.Media.Protocol.*` and are not part of the stable surface. It uses
two entry points over one content vocabulary:

- a completion that may return generated media (`Request.modalities`, decoded
  into `Response.content`), and
- a dedicated media request (`LlmCall.Media.Request` -> `LlmCall.Media.Response`), which may be
  synchronous or a long-running operation.

The reason for two entry points is that dedicated image/video endpoints have no
`messages`, `system`, or `tools`; flattening a completion request into
`{prompt, n, size}` would be a hidden convention.

### 23.1 Canonical additions

```elixir
defmodule LlmCall.Content.Video do
  @type t :: %__MODULE__{
          source: LlmCall.Content.source(),
          media_type: String.t() | nil
        }
  defstruct [:source, :media_type]
end

defmodule LlmCall.Media.Request do
  @type modality :: :image | :video

  @type params :: %{
          optional(:n) => pos_integer() | nil,
          optional(:size) => String.t() | nil,
          optional(:aspect_ratio) => String.t() | nil,
          optional(:duration_s) => pos_integer() | nil,
          optional(:seed) => non_neg_integer() | nil,
          optional(:negative_prompt) => String.t() | nil
        }

  @type t :: %__MODULE__{
          modality: modality(),
          model: String.t(),
          prompt: String.t(),
          references: nil | [LlmCall.Content.Image.t() | LlmCall.Content.Video.t()],
          params: params(),
          provider_options: map()
        }
end

defmodule LlmCall.Media.Response do
  @type asset :: LlmCall.Content.Image.t() | LlmCall.Content.Video.t()

  @type t :: %__MODULE__{
          assets: [asset()],
          revised_prompt: String.t() | nil,
          usage: LlmCall.Usage.t() | nil,
          operation: LlmCall.Operation.t() | nil,
          raw: map() | nil
        }
end

defmodule LlmCall.Operation do
  @type status :: :queued | :in_progress | :completed | :failed

  @type t :: %__MODULE__{
          id: String.t() | nil,
          status: status(),
          progress: 0..100 | nil,
          result: LlmCall.Media.Response.t() | nil,
          next: LlmCall.EncodedRequest.t() | nil,
          next_kind: :poll | :asset | nil,
          next_media_type: String.t() | nil,
          error: LlmCall.Error.t() | nil,
          raw: map() | nil
        }
end

defmodule LlmCall.Media.Capabilities do
  @type t :: %__MODULE__{
          modalities: [LlmCall.Media.Request.modality()],
          async: boolean(),
          max_n: pos_integer() | :unsupported,
          sizes: [String.t()],
          aspect_ratios: [String.t()],
          durations_s: [pos_integer()],
          max_references: non_neg_integer() | nil,
          seed: boolean(),
          negative_prompt: boolean()
        }
end
```

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
and merged like the completion side; a key that would replace `model`, `prompt`,
`instances`, or `modality` is a validation error. A protocol's own nested
parameter object stays reachable: `parameters` is not reserved, because
`Config.deep_merge/2` recurses into it, so a native Imagen knob such as
`personGeneration` merges beside the canonical `sampleCount`.

### 23.4 Operation state machine

One rule governs every operation:

- `next` is always the encoded request the transport executes next, built by the
  codec. There is no "encode a poll request from an id" callback.
- `decode_operation/3` receives only the payload and the config. A codec is
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

The core never polls, sleeps, retries, or downloads. A caller loop is:

```elixir
{:ok, %LlmCall.Media.Response{operation: %Operation{status: :in_progress} = op}} =
  LlmCall.decode_media(codec, submit_term, config)

execute(op.next)
{:ok, %Operation{status: :completed, next: next, next_kind: :asset}} =
  LlmCall.decode_operation(codec, poll_term, config)

execute(next)  # body is the media bytes
```

`Operation.raw` follows `capture_raw` (`:response` and `:all`).

### 23.5 `LlmCall.Media.Codec` behaviour and public API

```elixir
defmodule LlmCall.Media.Codec do
  @callback info() :: LlmCall.Codec.Info.t()
  @callback capabilities(LlmCall.Media.Request.t(), LlmCall.Config.t()) ::
              LlmCall.Media.Capabilities.t()
  @callback validate_request(LlmCall.Media.Request.t(), LlmCall.Config.t()) ::
              :ok | {:error, LlmCall.Error.t()}
  @callback encode_submit(LlmCall.Media.Request.t(), LlmCall.Config.t()) ::
              {:ok, LlmCall.EncodedRequest.t()} | {:error, LlmCall.Error.t()}
  @callback decode_submit(LlmCall.wire_value(), LlmCall.Config.t()) ::
              {:ok, LlmCall.Media.Response.t()} | {:error, LlmCall.Error.t()}
  @callback decode_operation(LlmCall.wire_value(), LlmCall.Config.t()) ::
              {:ok, LlmCall.Operation.t()} | {:error, LlmCall.Error.t()}
  @callback decode_error(LlmCall.wire_value(), LlmCall.Config.t()) :: LlmCall.Error.t()

  @optional_callbacks decode_operation: 2
end
```

```elixir
LlmCall.encode_media(codec, media_request, config \\ %LlmCall.Config{})
LlmCall.decode_media(codec, term, config \\ %LlmCall.Config{})
LlmCall.decode_operation(codec, term, config \\ %LlmCall.Config{})
LlmCall.validate_media(codec, media_request, config \\ %LlmCall.Config{})
LlmCall.media_capabilities(codec, media_request, config \\ %LlmCall.Config{})
```

`encode_media/3` delegates to the codec, which validates first. `decode_operation/3`
returns a typed `:validation` error when the codec has no `decode_operation/2`,
exactly like the optional streaming callbacks.

Media codecs reuse `LlmCall.Codec.Info`. `ir_version` stays `1`: adding optional
canonical fields with defaults does not change the contract an existing codec was
written against.

### 23.6 Protocol adapters

The media adapters are **vendored** with the library under
`LlmCall.Media.Protocol.*`: they ship in the `llm_call` application, follow the
same conformance suite as the reference chat adapters, and are not part of the
stable API surface (see `LlmCall.Media`). The media IR they map into is stable;
they are not.

Phase M1, synchronous image:

- `LlmCall.Media.Protocol.OpenAI.Images` — `POST /v1/images/generations`, body
  `{model, prompt, n?, size?}`. `response_format: "b64_json"` is sent only for
  `dall-e-*` models: `gpt-image-1` rejects the key and returns base64 anyway, and
  `provider_options.openai` may override the value. `references`,
  `aspect_ratio`, `duration_s`, `negative_prompt`, and `seed` are validation
  errors. Response `data[]`: `b64_json` -> `{:base64, data}`, `url` -> `{:url, url}`.
  `revised_prompt` is the first non-nil value; the rest stay in `raw`.
- `LlmCall.Media.Protocol.Gemini.Predict` (Imagen) — `POST /v1beta/models/{model}:predict`,
  body `{instances: [{prompt}], parameters: {sampleCount?, aspectRatio?, negativePrompt?}}`.
  `size`, `duration_s`, `seed`, and `references` are validation errors. Native
  `parameters` knobs (`personGeneration`, `safetySetting`, `outputOptions`, ...)
  merge through `provider_options`. Response `predictions[].bytesBase64Encoded`
  plus `mimeType` -> base64 image; a prediction with `raiFilteredReason` and no
  bytes is skipped while another prediction has bytes, and is a `:provider` error
  when none do.

Phase M2, asynchronous video. The M2 codecs target the two video APIs this
project actually uses; Sora and Veo are not implemented.

- `LlmCall.Media.Protocol.Seedance.Video` (BytePlus ModelArk) — submit
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
- `LlmCall.Media.Protocol.MiniMax.Video` (Hailuo, `v1`) — submit
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
