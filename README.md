# LlmCall

A wire-protocol codec for LLM APIs.

`LlmCall` turns a provider-neutral request into the body, path, and protocol
headers a provider expects, and turns a provider response term into a
provider-neutral response. It owns no HTTP client, authentication, model
registry, tool execution, retries, or agent loop — a codec returns
JSON-compatible Elixir terms, and your transport does the rest.

```elixir
request = %LlmCall.Request{
  model: "claude-sonnet-4-5",
  params: %{max_tokens: 1024},
  system: [%LlmCall.Content.Text{text: "You are helpful."}],
  messages: [
    %LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "Hello"}]}
  ]
}

config = %LlmCall.Config{capture_raw: :none}
codec = LlmCall.Protocol.Anthropic.Messages

{:ok, encoded} = LlmCall.encode(codec, request, config)
# Your transport: POST base_url <> encoded.path, JSON-encode encoded.body,
# add credentials. encoded.headers carries protocol headers only.

{:ok, response} = LlmCall.decode_response(codec, decoded_body, config)
IO.puts(LlmCall.Response.text(response))
```

Streaming is codec-driven and transport-owned: your transport parses SSE, then
feeds decoded events to `LlmCall.decode_stream_event/4`. Tool-call fragments are
assembled into complete calls by a pure helper, which never runs them:

```elixir
assembler = LlmCall.StreamAssembler.new(json_decoder: &JSON.decode/1)

{:ok, assembler, calls} =
  Enum.reduce(events, {:ok, assembler, []}, fn event, {:ok, acc, calls} ->
    {:ok, acc, new_calls} = LlmCall.StreamAssembler.feed(acc, event)
    {:ok, acc, calls ++ new_calls}
  end)

# When the transport reports the end of the stream:
{:ok, closing_events, state} = LlmCall.finish_stream(codec, state, config)
```

`LlmCall.finish_stream/3` is required for Gemini: it sends no stream
terminator, so accumulated usage and `:message_stop` arrive only there.

## Media generation

A completion can ask for image output; the generated parts arrive in the normal
`Response.content`:

```elixir
codec = LlmCall.Protocol.Gemini.GenerateContent

request = %LlmCall.Request{
  model: "gemini-2.5-flash-image",
  modalities: [:text, :image],
  messages: [%LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "a cat"}]}]
}

{:ok, encoded} = LlmCall.encode(codec, request)
# ...
{:ok, response} = LlmCall.decode_response(codec, decoded_body)
# response.content may now contain %LlmCall.Content.Image{}
```

Dedicated image endpoints use the media API instead, because they take a prompt
and media parameters rather than messages:

```elixir
media = %LlmCall.MediaRequest{
  modality: :image,
  model: "gpt-image-1",
  prompt: "a cat, watercolor",
  params: %{n: 2, size: "1024x1024"}
}

{:ok, encoded} = LlmCall.encode_media(LlmCall.Protocol.OpenAI.Images, media)
# ...
{:ok, %LlmCall.MediaResponse{assets: assets}} =
  LlmCall.decode_media(LlmCall.Protocol.OpenAI.Images, decoded_body)
```

`LlmCall.media_capabilities/3` reports what a codec accepts for each media knob,
and a knob the codec cannot express is a validation error rather than a silent
drop.

Asynchronous video uses the same media API. A submit response carries an
`%LlmCall.Operation{}` whose `next` is the request the transport sends next, and
`LlmCall.decode_operation/3` returns the next state:

```elixir
{:ok, %LlmCall.MediaResponse{operation: op}} =
  LlmCall.decode_media(LlmCall.Protocol.Seedance.Video, submit_body)

# transport: execute op.next (a GET), then feed the decoded body back
{:ok, %LlmCall.Operation{status: :in_progress} = op} =
  LlmCall.decode_operation(LlmCall.Protocol.Seedance.Video, poll_body)
```

The core never polls, waits, or downloads. `next_kind: :poll` means "execute
`next` and feed the body back to `decode_operation/3`"; `next_kind: :asset` means
the body is the media bytes and the caller stores them. A job ends when
`status: :completed` carries assets, or `:failed` carries an error.

Implemented async codecs:

| Codec | Flow |
| --- | --- |
| `LlmCall.Protocol.Seedance.Video` | submit -> poll the task -> `content.video_url` |
| `LlmCall.Protocol.MiniMax.Video` | submit -> poll the task -> on `Success` poll `/v1/files/retrieve` -> `file.download_url` |

## Protocol adapters

| Protocol | Module |
| --- | --- |
| OpenAI Chat Completions | `LlmCall.Protocol.OpenAI.Chat` |
| Anthropic Messages | `LlmCall.Protocol.Anthropic.Messages` |
| Gemini GenerateContent | `LlmCall.Protocol.Gemini.GenerateContent` |
| OpenAI Images (generation) | `LlmCall.Protocol.OpenAI.Images` |
| Gemini Imagen (generation) | `LlmCall.Protocol.Gemini.Predict` |

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

Third-party codecs can check themselves against
`LlmCall.Codec.Conformance` (test support, not a runtime dependency).
