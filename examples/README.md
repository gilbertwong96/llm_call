# Examples

Reference provider definitions. They are compiled in `:dev` and `:test` so they
cannot rot, and excluded from the Hex package.

A provider is a module you write, not a catalog entry:

```elixir
defmodule MyApp.Groq do
  use LlmCall.Provider,
    base_url: "https://api.groq.com/openai",
    auth: :bearer,
    codecs: [chat: LlmCall.Dialect.OpenAI.Chat]
end
```

## One call

```elixir
client = LlmCall.Examples.OpenAI.client(api_key: System.fetch_env!("OPENAI_API_KEY"))

request = %LlmCall.Request{
  model: "gpt-4o",
  messages: [%LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "Hi"}]}]
}

{:ok, %LlmCall.Response{} = response} = LlmCall.complete(client, request)
LlmCall.Response.text(response)
```

`codecs:` is a named map, because one endpoint can serve several request shapes:

```elixir
{:ok, %LlmCall.Media.Response{} = media} =
  LlmCall.generate(client, %LlmCall.Media.Request{modality: :image, model: "gpt-image-1", prompt: "a cat"}, codec: :images)
```

Streaming returns a lazy `Enumerable`; a failure while reading raises
`LlmCall.HTTP.Error`, which carries the canonical error:

```elixir
{:ok, stream} = LlmCall.stream(client, %{request | stream: true})

stream
|> Stream.each(&IO.inspect(&1.type))
|> Stream.run()
```

## JSON and transport

HTTP is Finch. JSON is the `LlmCall.JSON` facade over Elixir's built-in `JSON`,
resolved at compile time from `config :llm_call, :json_library`, then per client:

```elixir
# config/config.exs
config :llm_call,
  json_library: Jason,
  http_opts: [name: MyApp.Finch],
  timeout: 30_000
```

```elixir
# per provider, or per client
use LlmCall.Provider, json_library: Jason, ...
MyProvider.client(api_key: key, json_library: Jason)
```

The JSON module is written into the client's `%LlmCall.Config{}`, so the codecs
decode tool-call arguments with the same implementation as the transport.

## Tools

Tool wire data lives here; schema derivation and dispatch do not. Use
[`tool_call`](https://hex.pm/packages/tool_call) directly:

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
    %LlmCall.ToolSpec{name: tool.name, description: tool.description, parameters: tool.parameters}
  end

request = %{request | tools: tools}
{:ok, response} = LlmCall.complete(client, request)

for call <- LlmCall.Response.tool_calls(response) do
  {:ok, result} = ToolCall.run(MyApp.Tools.Weather, String.to_existing_atom(call.name), call.arguments)
  # build the %LlmCall.ToolResult{} and send the next request yourself
end
```

## Hosted tools

A provider-hosted tool (web search, grounding, server tools) is a builtin tool
whose `name` is the vendor's own identifier:

```elixir
%LlmCall.ToolSpec{kind: :builtin, name: "web_search_20250305", provider_options: %{"max_uses" => 5}}
```

The codec forwards it verbatim when it declares `builtin_tools: :passthrough`;
otherwise it is a validation error. Results stay in `%LlmCall.Content.Raw{}` until
a second codec needs a shared shape for them.
