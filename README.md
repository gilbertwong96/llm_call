# LlmCall

A call-oriented SDK for LLM APIs: a canonical IR, protocol codecs, and a one-call
client on Finch whose JSON layer you can replace.

```elixir
defmodule MyApp.OpenAI do
  use LlmCall.Provider,
    base_url: "https://api.openai.com",
    auth: :bearer,
    codecs: [chat: LlmCall.Protocol.OpenAI.Chat]
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
    {:llm_call, "~> 0.1.0"}
  ]
end
```

Requires Elixir 1.18+ on OTP 27+. Runtime dependencies are Finch and
`mint_web_socket`; everything else is dev/test only.

## Providers

A provider is a module you write: endpoint, auth shape, and the codecs it serves.
There is no built-in catalog — `examples/` carries reference definitions.

```elixir
defmodule MyApp.Groq do
  use LlmCall.Provider,
    base_url: "https://api.groq.com/openai",
    auth: :bearer,
    codecs: [chat: LlmCall.Protocol.OpenAI.Chat]
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
wins on the same key:

```elixir
defmodule MyApp.MiniMax do
  use LlmCall.Provider,
    base_url: "https://api.minimax.io",
    auth: :bearer,
    codecs: [video: LlmCall.Media.Protocol.MiniMax.Video]
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

### Responses over WebSocket

The Responses protocol also has a multiplexed WebSocket connection:
named `stream_id` lanes, decoded events, and reconnect before the 60-minute
limit.

```elixir
{:ok, connection} = LlmCall.Protocol.OpenAI.Responses.Connection.start_link(client: client)
{:ok, stream} = LlmCall.Protocol.OpenAI.Responses.Connection.create(connection, request, stream_id: "main")

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
  http_opts: [name: MyApp.Finch],
  timeout: 30_000
```

`Torque`, `Jason` and `Poison` expose tagged `encode/1`/`decode/1`; Elixir
`JSON` exposes `encode!/1`/`decode!/1`. The `LlmCall.JSON` facade accepts either
shape and normalizes it, so no adapter module is needed. `json_library:` is the
single configuration key, matching Phoenix.

The application default is read with `Application.compile_env/3`; changing it
requires recompiling the library. Per-client `json_library:` and provider
declarations still override it without touching the compiled default. An
explicit `%LlmCall.Config{}` uses the compiled default.

`LlmCall.Application` starts a Finch pool named `LlmCall.Finch`; pass
`http_opts: [name: MyPool]` to use your own. If that name is already taken when
`:llm_call` starts, the existing pool is used and no second one is started.

## Tools

Tool data is wire data only: `LlmCall.ToolSpec`, `LlmCall.ToolCall` and
`LlmCall.ToolResult`. The library does not derive schemas or dispatch calls — the
[`tool_call`](https://hex.pm/packages/tool_call) package does that well, so use it
directly and map its provider-neutral descriptions into canonical specs:

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

tools =
  for tool <- ToolCall.describe(MyApp.Tools.Weather) do
    %LlmCall.ToolSpec{
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  end

request = %{request | tools: tools}
{:ok, response} = LlmCall.complete(client, request)

for call <- LlmCall.Response.tool_calls(response) do
  {:ok, result} = ToolCall.run(MyApp.Tools.Weather, String.to_existing_atom(call.name), call.arguments)
  # build the %LlmCall.ToolResult{} and send the next request yourself
end
```

Approvals, audits and timeouts stay in `tool_call`, and the follow-up request stays
with you: the library does not run an agent loop.

Provider-hosted tools (web search, grounding, server tools) are builtin tools whose
`name` is the vendor's own identifier; the codec forwards them verbatim when it
declares `builtin_tools: :passthrough`:

```elixir
%LlmCall.ToolSpec{kind: :builtin, name: "web_search_20250305", provider_options: %{"max_uses" => 5}}
```

## Protocol adapters

Four **reference adapters** — the dialect families the IR is written against:

| Protocol | Module |
| --- | --- |
| OpenAI Chat Completions | `LlmCall.Protocol.OpenAI.Chat` |
| OpenAI Responses | `LlmCall.Protocol.OpenAI.Responses` |
| Anthropic Messages | `LlmCall.Protocol.Anthropic.Messages` |
| Gemini GenerateContent | `LlmCall.Protocol.Gemini.GenerateContent` |

And four **vendored media adapters**, which ship with the library but are not part
of the stable API surface (see `LlmCall.Media`):

| Protocol | Module |
| --- | --- |
| OpenAI Images | `LlmCall.Media.Protocol.OpenAI.Images` |
| Gemini Imagen `predict` | `LlmCall.Media.Protocol.Gemini.Predict` |
| Seedance (BytePlus ModelArk) | `LlmCall.Media.Protocol.Seedance.Video` |
| MiniMax Hailuo | `LlmCall.Media.Protocol.MiniMax.Video` |

The library does not promise provider coverage. An adapter outside this repository
is a module that `use`s `LlmCall.Protocol.Adapter` (or `LlmCall.Media.Adapter`) and
supplies `@path`, `@headers`, a private `body/2`, and the protocol's own
`validate_request/2`; share validation through `LlmCall.Protocol.Helpers` instead
of reimplementing it. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

OpenAI-compatible endpoints (Groq, DeepSeek, Together, vLLM, Ollama's OpenAI
surface, ...) use the OpenAI Chat codec with their own base URL and
`provider_options`; their capabilities are not uniform.

## Two levels

The one-call client is the default. The encode/decode functions stay available for
callers that already own a transport:

```elixir
{:ok, encoded} = LlmCall.encode(LlmCall.Protocol.Anthropic.Messages, request)
# transport: encoded.method to base_url <> encoded.path, JSON-encode encoded.body
{:ok, response} = LlmCall.decode_response(LlmCall.Protocol.Anthropic.Messages, payload)
```

## Design

See [`docs/design.md`](docs/design.md) for the canonical IR, the codec contract,
the streaming model, the client, and the failure and compatibility policy.

Adapters check themselves with `LlmCall.Codec.Conformance` or
`LlmCall.MediaConformance` (test support published from `lib/`, not a runtime
dependency). The vendored media adapters run the media suite in this repository's
own `mix test`.
