# LlmDialect

A wire-protocol codec for LLM APIs.

`LlmDialect` turns a provider-neutral request into the body, path, and protocol
headers a provider expects, and turns a provider response term into a
provider-neutral response.

## Installation

Add `llm_dialect` to your dependencies. It has no runtime dependencies.

```elixir
def deps do
  [
    {:llm_dialect, "~> 0.1.0"}
  ]
end
```

Requires Elixir 1.18+ on OTP 27+ (the `:json` module ships with OTP 27). It owns no HTTP client, authentication, model
registry, tool execution, retries, or agent loop — a codec returns
JSON-compatible Elixir terms, and your transport does the rest.

```elixir
request = %LlmDialect.Request{
  model: "claude-sonnet-4-5",
  params: %{max_tokens: 1024},
  system: [%LlmDialect.Content.Text{text: "You are helpful."}],
  messages: [
    %LlmDialect.Message{role: :user, content: [%LlmDialect.Content.Text{text: "Hello"}]}
  ]
}

config = %LlmDialect.Config{capture_raw: :none}
codec = LlmDialect.Protocol.Anthropic.Messages

{:ok, encoded} = LlmDialect.encode(codec, request, config)
# Your transport: POST base_url <> encoded.path, JSON-encode encoded.body,
# add credentials. encoded.headers carries protocol headers only.

{:ok, response} = LlmDialect.decode_response(codec, decoded_body, config)
IO.puts(LlmDialect.Response.text(response))
```

Streaming is codec-driven and transport-owned: your transport parses SSE, then
feeds decoded events to `LlmDialect.decode_stream_event/4`. Tool-call fragments are
assembled into complete calls by a pure helper, which never runs them:

```elixir
assembler = LlmDialect.StreamAssembler.new(json_decoder: &JSON.decode/1)

{:ok, assembler, calls} =
  Enum.reduce(events, {:ok, assembler, []}, fn event, {:ok, acc, calls} ->
    {:ok, acc, new_calls} = LlmDialect.StreamAssembler.feed(acc, event)
    {:ok, acc, calls ++ new_calls}
  end)

# When the transport reports the end of the stream:
{:ok, closing_events, state} = LlmDialect.finish_stream(codec, state, config)
```

`LlmDialect.finish_stream/3` is required for Gemini: it sends no stream
terminator, so accumulated usage and `:message_stop` arrive only there.

## Media generation

A completion can ask for image output; the generated parts arrive in the normal
`Response.content`:

```elixir
codec = LlmDialect.Protocol.Gemini.GenerateContent

request = %LlmDialect.Request{
  model: "gemini-2.5-flash-image",
  modalities: [:text, :image],
  messages: [%LlmDialect.Message{role: :user, content: [%LlmDialect.Content.Text{text: "a cat"}]}]
}

{:ok, encoded} = LlmDialect.encode(codec, request)
# ...
{:ok, response} = LlmDialect.decode_response(codec, decoded_body)
# response.content may now contain %LlmDialect.Content.Image{}
```

Dedicated image endpoints use the media API instead, because they take a prompt
and media parameters rather than messages:

```elixir
media = %LlmDialect.Media.Request{
  modality: :image,
  model: "gpt-image-1",
  prompt: "a cat, watercolor",
  params: %{n: 2, size: "1024x1024"}
}

{:ok, encoded} = LlmDialect.encode_media(LlmDialect.Media.Protocol.OpenAI.Images, media)
# ...
{:ok, %LlmDialect.Media.Response{assets: assets}} =
  LlmDialect.decode_media(LlmDialect.Media.Protocol.OpenAI.Images, decoded_body)
```

`LlmDialect.media_capabilities/3` (returning `{:ok, capabilities}`) reports what a
codec accepts for each media knob: `max_n: :unsupported` means no `n`, and
`max_references` is the number of reference images the endpoint takes. A knob the
codec cannot express is a validation error rather than a silent drop.

Asynchronous video uses the same media API. A submit response carries an
`%LlmDialect.Operation{}` whose `next` is the request the transport sends next, and
`LlmDialect.decode_operation/3` returns the next state:

```elixir
{:ok, %LlmDialect.Media.Response{operation: op}} =
  LlmDialect.decode_media(LlmDialect.Media.Protocol.Seedance.Video, submit_body)

# transport: execute op.next (a GET), then feed the decoded body back
{:ok, %LlmDialect.Operation{status: :in_progress} = op} =
  LlmDialect.decode_operation(LlmDialect.Media.Protocol.Seedance.Video, poll_body)
```

The core never polls, waits, or downloads. `next_kind: :poll` means "execute
`next` and feed the body back to `decode_operation/3`"; `next_kind: :asset` means
the body is the media bytes and the caller stores them. A job ends when
`status: :completed` carries assets, or `:failed` carries an error.

The video adapters are `LlmDialect.Media.Protocol.Seedance.Video` and
`LlmDialect.Media.Protocol.MiniMax.Video`.

## Protocol adapters

Three **reference adapters** — the dialect families the IR is written against:

| Protocol | Module |
| --- | --- |
| OpenAI Chat Completions | `LlmDialect.Protocol.OpenAI.Chat` |
| Anthropic Messages | `LlmDialect.Protocol.Anthropic.Messages` |
| Gemini GenerateContent | `LlmDialect.Protocol.Gemini.GenerateContent` |

And four **vendored media adapters**, which ship with the library but are not part
of the stable API surface (see `LlmDialect.Media`):

| Protocol | Module |
| --- | --- |
| OpenAI Images | `LlmDialect.Media.Protocol.OpenAI.Images` |
| Gemini Imagen `predict` | `LlmDialect.Media.Protocol.Gemini.Predict` |
| Seedance (BytePlus ModelArk) | `LlmDialect.Media.Protocol.Seedance.Video` |
| MiniMax Hailuo | `LlmDialect.Media.Protocol.MiniMax.Video` |

The library does not promise provider coverage. An adapter outside this
repository is a module that `use`s `LlmDialect.Protocol.Adapter` (or
`LlmDialect.Media.Adapter`) and supplies `@path`, `@headers`, a private `body/2`,
and the protocol's own `validate_request/2`; share validation through
`LlmDialect.Protocol.Helpers` instead of reimplementing it. See
[`CONTRIBUTING.md`](CONTRIBUTING.md).

Codec selection is explicit; there is no provider registry. OpenAI-compatible
endpoints (Groq, DeepSeek, Together, vLLM, Ollama's OpenAI surface, ...) use the
OpenAI Chat codec with their own base URL and `provider_options`; their
capabilities are not uniform.

## Dependencies

None at runtime. The OTP standard library's `:json` module is used only where a
wire format requires an actual JSON string.

## Design

See [`docs/design.md`](docs/design.md) for the canonical IR, the codec contract,
the streaming model, and the failure and compatibility policy.

Adapters check themselves with `LlmDialect.Codec.Conformance` or
`LlmDialect.MediaConformance` (test support published from `lib/`, not a runtime
dependency). The vendored media adapters run the media suite in this repository's
own `mix test`.
