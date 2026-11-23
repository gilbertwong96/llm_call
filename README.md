# LlmCall

[![CI](https://github.com/gilbertwong96/llm_call/actions/workflows/ci.yml/badge.svg)](https://github.com/gilbertwong96/llm_call/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/gilbertwong96/llm_call/graph/badge.svg)](https://codecov.io/gh/gilbertwong96/llm_call)
[![Elixir](https://img.shields.io/badge/elixir-1.18+-purple.svg)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Hex.pm](https://img.shields.io/hexpm/v/llm_call.svg)](https://hex.pm/packages/llm_call)

A call-oriented SDK for LLM APIs: a canonical IR, dialect codecs, and a one-call
client on Finch whose JSON layer you can replace.

```elixir
defmodule MyApp.OpenAI do
  use LlmCall.Provider,
    base_url: "https://api.openai.com",
    auth: :bearer,
    codecs: [chat: LlmCall.Dialect.OpenAI.Chat]
end

client = MyApp.OpenAI.client(api_key: System.fetch_env!("OPENAI_API_KEY"))

request = %LlmCall.Request{
  model: "gpt-4o",
  messages: [%LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "Hello"}]}]
}

{:ok, response} = LlmCall.complete(client, request)
LlmCall.Response.text(response)
```

`complete/3` validates, encodes, sends, and decodes. `stream/3` does the same and
returns a lazy `Enumerable` of events. `generate/3` and `poll/3` cover dedicated
image and video endpoints, including long-running jobs.

## Installation

```elixir
def deps do
  [
    {:llm_call, "~> 0.2.0"}
  ]
end
```

Requires Elixir 1.18+ on OTP 27.1+. Runtime dependencies are Finch, `mint`,
`mint_web_socket` and `tool_call` (which brings no runtime dependency of its
own); everything else is dev/test only.

## Providers

A provider is a module you write: endpoint, auth shape, and the codecs it serves.
There is no built-in catalog — `examples/` carries reference definitions.

```elixir
defmodule MyApp.Groq do
  use LlmCall.Provider,
    base_url: "https://api.groq.com/openai",
    auth: :bearer,
    codecs: [chat: LlmCall.Dialect.OpenAI.Chat]
end

client = MyApp.Groq.client(api_key: key)
```

`codecs:` is a named map because one endpoint can serve several request shapes.
An endpoint that returns text and images is still **one** chat codec
(`modalities: [:text, :image]`); a different request shape — Imagen's `predict`,
OpenAI Images — is a second codec selected per call:

```elixir
{:ok, %LlmCall.Media.Response{assets: assets}} =
  LlmCall.generate(client, media_request, codec: :images)
```

Auth shapes: `:none`, `:bearer`, `:x_api_key`, `{:header, name}`, or
`{module, function}`. The key is always passed in; nothing reads the environment.

`query:` adds URL parameters to every request, for vendors that key on one —
MiniMax's `GroupId`, Azure OpenAI's `api-version`. A codec's own parameter still
wins on the same key, and the Responses WebSocket handshake gets them too. A
query already written into `base_url` is folded into `query:` when the client is
built, so pasting `https://…/openai?api-version=2024-02-01` works.

```elixir
defmodule MyApp.MiniMax do
  use LlmCall.Provider,
    base_url: "https://api.minimax.io",
    auth: :bearer,
    codecs: [video: LlmCall.Media.Dialect.MiniMax.Video]
end

client =
  MyApp.MiniMax.client(
    api_key: System.fetch_env!("MINIMAX_API_KEY"),
    query: %{"GroupId" => System.fetch_env!("MINIMAX_GROUP_ID")}
  )
```

The declaration only takes literals, so a value read at runtime belongs on
`client/1`.

## Streaming

```elixir
{:ok, stream} = LlmCall.stream(client, %{request | stream: true})

stream
|> Stream.each(&IO.inspect({&1.type, &1.delta}))
|> Stream.run()
```

The library parses SSE and provider terminators. A failure while the body is being
read raises `LlmCall.HTTP.Error`, whose `error/1` returns the canonical
`%LlmCall.Error{}` with the HTTP status; `{:halt, acc}` from a reducer closes the
connection. `complete/3` rejects `stream: true` rather than silently flipping it.

To observe events without owning the reduce, pass `on_event:`:

```elixir
{:ok, stream} =
  LlmCall.stream(client, request, on_event: &MyApp.Audit.stream_event/1)
```

It runs before the reducer, including for `finish_stream/2` output; the return
value is ignored, and it is not called after the reducer halts. `LlmCall.HTTP` is
the only HTTP transport, so raw bytes are not exposed as a hook.

A reasoning block spans several events. The text arrives incrementally, and a
provider that signs its thinking blocks sends the signature in its own event, with
an empty `text` — Anthropic on every block, Gemini on the thought parts before a
function call. Keep both when you fold the stream into an assistant turn, or the
block cannot be replayed in the next request:

```elixir
def merge(%LlmCall.Content.Thinking{} = block, %LlmCall.StreamDelta.Thinking{} = delta) do
  %{block | text: block.text <> delta.text, signature: delta.signature || block.signature}
end
```

### Responses over WebSocket

The Responses protocol also has a multiplexed WebSocket connection:
named `stream_id` lanes, decoded events, and reconnect before the 60-minute
limit.

```elixir
{:ok, connection} = LlmCall.Dialect.OpenAI.Responses.Connection.start_link(client: client)
{:ok, stream} = LlmCall.Dialect.OpenAI.Responses.Connection.create(connection, request, stream_id: "main")

Enum.to_list(stream)
```

An in-flight response cannot resume across a reconnect; its stream raises
`LlmCall.WS.Error`. The connection reconnects with exponential backoff and does
not stop on failure: while disconnected, `create/3` returns a `:transport` error
and `Connection.reconnect/1` retries immediately. `Connection.response_id/2`
returns the provider id for `previous_response_id`.

Tool-call fragments are assembled into complete calls by a pure helper, which never
runs them:

```elixir
assembler = LlmCall.StreamAssembler.new(json_decoder: &JSON.decode/1)

{:ok, assembler, calls} =
  Enum.reduce(events, {:ok, assembler, []}, fn event, {:ok, acc, calls} ->
    {:ok, acc, new_calls} = LlmCall.StreamAssembler.feed(acc, event)
    {acc, calls ++ new_calls}
  end)
```

## Media generation

A completion can ask for image output; generated parts arrive in
`Response.content`:

```elixir
request = %LlmCall.Request{
  model: "gemini-2.5-flash-image",
  modalities: [:text, :image],
  messages: [%LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "a cat"}]}]
}

{:ok, response} = LlmCall.complete(client, request)
# response.content may contain %LlmCall.Content.Image{}
```

Dedicated endpoints take a prompt and media parameters instead of messages:

```elixir
media = %LlmCall.Media.Request{
  modality: :image,
  model: "gpt-image-1",
  prompt: "a cat, watercolor",
  params: %{n: 2, size: "1024x1024"}
}

{:ok, %LlmCall.Media.Response{assets: assets}} =
  LlmCall.generate(client, media, codec: :images)
```

Asynchronous video returns an `%LlmCall.Operation{}` whose `next` is the request
to execute; `poll/3` runs it and returns the next state:

```elixir
{:ok, %LlmCall.Media.Response{operation: op}} = LlmCall.generate(client, video, codec: :video)
{:ok, %LlmCall.Operation{status: :completed} = done} = LlmCall.poll(client, op, codec: :video)
```

`next_kind: :poll` means "execute `next` and poll"; `next_kind: :asset` means the
body is media bytes — use `LlmCall.fetch/2` for it. The library never polls,
waits, or downloads on its own.

`LlmCall.media_capabilities/3` reports what a codec accepts: `max_n:
:unsupported` means no `n`, `max_references` is the reference count. A knob the
codec cannot express is a validation error, never a silent drop.

## Replaceable JSON layer

HTTP is Finch, one implementation. JSON is a module resolved at client-build
time: the call option, the provider declaration, the compile-time application
default, then Elixir's built-in `JSON`.

| Layer | Module | Default |
| --- | --- | --- |
| JSON | `LlmCall.JSON` facade | Elixir `JSON` |

```elixir
# config/config.exs of the host application
config :llm_call,
  json_library: Torque,
  capture_raw: :response,
  http_opts: [name: MyApp.Finch],
  timeout: 30_000
```

`Torque`, `Jason` and `Poison` expose tagged `encode/1`/`decode/1`; Elixir
`JSON` exposes `encode!/1`/`decode!/1`. The `LlmCall.JSON` facade accepts either
shape and normalizes it, so no adapter module is needed. `json_library:` is the
single configuration key, matching Phoenix.

`json_library` and `capture_raw` are read with `Application.compile_env/3`;
changing them requires recompiling the library. Per-client `json_library:`,
`capture_raw:` (through `LlmCall.Config.new/1`) and provider declarations still
override them without touching the compiled default. An explicit
`%LlmCall.Config{}` uses the compiled default for both.

`LlmCall.Application` starts a Finch pool named `LlmCall.Finch`; pass
`http_opts: [name: MyPool]` to use your own. If that name is already taken when
`:llm_call` starts, the existing pool is used and no second one is started.
`http_opts` accepts only `:name`, `:pool_timeout`, `:request_timeout` and
`:pool_strategy`; `timeout:` is the read timeout, and `receive_timeout` in
`http_opts` is rejected instead of ignored.

`timeout:` is Finch's `:receive_timeout`: each body chunk must arrive within it,
not the whole call, so a large response on a slow link can outlive it. Add
`http_opts: [request_timeout: ...]` when you want a wall-clock cap.

## Tools

`Request.tools` takes a [`tool_call`](https://hex.pm/packages/tool_call) module, a
`{module, opts}` pair, or a ready `%LlmCall.ToolSpec{}`; the three forms mix freely
in one list. Naming the module is the short form — the schema is derived from its
`@spec` and `@doc`, and projected into the selected codec's dialect:

```elixir
defmodule MyApp.Tools.Weather do
  use ToolCall

  @doc """
  Get the forecast for a city.

  ## Parameters
    * `city` - city name
  """
  @spec get_weather(city :: String.t()) :: {:ok, %{temp: float()}}
  def get_weather(city), do: {:ok, %{temp: 21.5}}
end

{:ok, response} =
  LlmCall.complete(client, %LlmCall.Request{
    model: "gpt-4o",
    messages: messages,
    tools: [MyApp.Tools.Weather]
  })

for call <- LlmCall.Response.tool_calls(response) do
  {:ok, _result} = ToolCall.run(MyApp.Tools.Weather, call.name, call.arguments)
  # build the %LlmCall.ToolResult{} and send the next request yourself
end
```

`{MyApp.Tools.Weather, strict: true}` asks for OpenAI's strict schema. Setting
`strict: false` is treated as absent rather than sent as a flag, and a codec
without a per-tool flag rejects `true`.

Approvals, audits and timeouts stay in `tool_call`, and the follow-up request stays
with you: the library does not run an agent loop.

The projection follows the codec, so no per-provider step is left to the caller:
the two OpenAI protocols get the schema `ToolCall.emit/3` renders for OpenAI,
Gemini the one rendered for Gemini, and any other protocol the neutral
`ToolCall.describe/2` schema. That is why Gemini needs no manual projection step,
and a schema the protocol cannot express is a `:validation` error instead of a
request the provider refuses — Gemini rejects a lowercase `type`,
`additionalProperties`, `$ref`/`$defs`, `prefixItems`, `oneOf`, `const`, `allOf`
or `not`.

Every entry point that forwards a request to a codec expands `tools` first:
`complete/3`, `stream/3`, `encode/3`, `validate_request/3`, `init_stream/3` and
`Responses.Connection.create/3`. `capabilities/3` reads no tools.

Pass a `%LlmCall.ToolSpec{}` when you already own a dialect-correct schema;
`LlmCall.Tools.expand/2` keeps it unchanged. Call `expand/2` directly when you
want the specs before the call:

```elixir
{:ok, specs} = LlmCall.Tools.expand([MyApp.Tools.Weather], LlmCall.Dialect.OpenAI.Chat)
```

What a decoded turn can be sent back as depends on the protocol: text and tool
calls always, thinking blocks and `Content.Raw` only where the request shape
allows it. `docs/design.md` §8.2 has the table, and
`LlmCall.Codec.Conformance.assert_replays/3` pins it for an adapter.

Provider-hosted tools (web search, grounding, server tools) are builtin tools whose
`name` is the vendor's own identifier; the codec forwards them verbatim when it
declares `builtin_tools: :passthrough`:

```elixir
%LlmCall.ToolSpec{kind: :builtin, name: "web_search_20250305", provider_options: %{"max_uses" => 5}}
```

## Dialect adapters

Four **reference adapters** — the dialect families the IR is written against:

| Dialect | Module |
| --- | --- |
| OpenAI Chat Completions | `LlmCall.Dialect.OpenAI.Chat` |
| OpenAI Responses | `LlmCall.Dialect.OpenAI.Responses` |
| Anthropic Messages | `LlmCall.Dialect.Anthropic.Messages` |
| Gemini GenerateContent | `LlmCall.Dialect.Gemini.GenerateContent` |

And four **vendored media adapters**, which ship with the library but are not part
of the stable API surface (see `LlmCall.Media`):

| Dialect | Module |
| --- | --- |
| OpenAI Images | `LlmCall.Media.Dialect.OpenAI.Images` |
| Gemini Imagen `predict` | `LlmCall.Media.Dialect.Gemini.Predict` |
| Seedance (BytePlus ModelArk) | `LlmCall.Media.Dialect.Seedance.Video` |
| MiniMax Hailuo | `LlmCall.Media.Dialect.MiniMax.Video` |

The library does not promise provider coverage. An adapter outside this repository
is a module that `use`s `LlmCall.Dialect.Adapter` (or `LlmCall.Media.Dialect.Adapter`) and
supplies `@path`, `@headers`, a private `body/2`, and the protocol's own
`validate_request/2`; share validation through `LlmCall.Dialect.Helpers` instead
of reimplementing it. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

OpenAI-compatible endpoints (Groq, DeepSeek, Together, vLLM, Ollama's OpenAI
surface, ...) use the OpenAI Chat codec with their own base URL and
`provider_options`; their capabilities are not uniform.

## Two levels

The one-call client is the default. The encode/decode functions stay available for
callers that already own a transport:

```elixir
{:ok, encoded} = LlmCall.encode(LlmCall.Dialect.Anthropic.Messages, request)
# transport: encoded.method to base_url <> encoded.path, JSON-encode encoded.body
{:ok, response} = LlmCall.decode_response(LlmCall.Dialect.Anthropic.Messages, payload)
```

## Design

See [`docs/design.md`](docs/design.md) for the canonical IR, the codec contract,
the streaming model, the client, and the failure and compatibility policy.
[`docs/roadmap.md`](docs/roadmap.md) records what 0.1 shipped and the order in which
further operation families (embeddings, rerank, speech, transcription) would arrive.

Adapters check themselves with `LlmCall.Codec.Conformance` or
`LlmCall.Media.Conformance` (test support published from `lib/`, not a runtime
dependency). The vendored media adapters run the media suite in this repository's
own `mix test`.
