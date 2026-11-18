defmodule LlmCall.Provider do
  @moduledoc """
  Declares a provider: where it lives, how it authenticates, and which codecs it
  serves.

      defmodule MyApp.OpenAI do
        use LlmCall.Provider,
          base_url: "https://api.openai.com/v1",
          auth: :bearer,
          codecs: [
            chat: LlmCall.Protocol.OpenAI.Chat,
            images: LlmCall.Media.Protocol.OpenAI.Images
          ]
      end

      client = MyApp.OpenAI.client(api_key: System.fetch_env!("OPENAI_API_KEY"))
      LlmCall.complete(client, request)

  A provider is a user module, not a catalog entry: the library ships no provider
  list. `auth` describes the *shape* of authentication, never the key; the key is
  always passed in.

  ## Seams

  `http`, `http_opts`, `json` and `timeout` may be declared here, and each
  resolves call option → provider → `config :llm_call, ...` → built-in default. The
  JSON module is written into the client's `%LlmCall.Config{}`, so the codecs use
  the same implementation as the transport.
  """

  alias LlmCall.{Client, Config}
  alias LlmCall.HTTP

  @default_timeout 60_000

  @doc """
  Builds a `%LlmCall.Client{}` from a provider module's declaration and options.

  Options: `api_key:`, `base_url:`, `headers:`, `http:`, `http_opts:`, `timeout:`,
  `json:`, `config:`.
  """
  @spec build(module(), keyword()) :: Client.t()
  def build(provider, opts \\ []) do
    declaration = provider.__provider__()

    config =
      opts
      |> base_config(declaration)
      |> put_json(opts[:json] || declaration[:json])

    %Client{
      provider: provider,
      codecs: Map.new(declaration.codecs),
      base_url: opts[:base_url] || declaration.base_url,
      headers: headers(declaration, opts),
      http: resolve(:http, opts, declaration, HTTP.Finch),
      http_opts: resolve(:http_opts, opts, declaration, []),
      timeout: resolve(:timeout, opts, declaration, @default_timeout),
      config: config
    }
  end

  defp headers(declaration, opts) do
    declaration.headers ++
      auth_headers(declaration.auth, opts[:api_key]) ++
      Keyword.get(opts, :headers, [])
  end

  defp resolve(key, opts, declaration, default) do
    opts[key] || declaration[key] || app_env(key) || default
  end

  defp base_config(opts, _declaration), do: opts[:config] || Config.new()

  defp put_json(config, nil), do: config
  defp put_json(%Config{} = config, json), do: %{config | json: json}

  defp app_env(key), do: Application.get_env(:llm_call, key)

  defp auth_headers(:none, _key), do: []

  defp auth_headers(:bearer, key), do: [{"authorization", "Bearer #{require_key(key)}"}]
  defp auth_headers(:x_api_key, key), do: [{"x-api-key", require_key(key)}]
  defp auth_headers({:header, name}, key), do: [{name, require_key(key)}]

  defp auth_headers({module, function}, key) when is_atom(module) and is_atom(function) do
    module.function(require_key(key))
  end

  defp require_key(nil) do
    raise ArgumentError, "api_key is required by this provider's auth"
  end

  defp require_key(key) when is_binary(key), do: key

  defp require_key(other) do
    raise ArgumentError, "api_key must be a string, got: #{inspect(other)}"
  end

  defp expand({module, function}, caller) when is_atom(function) do
    {expand(module, caller), function}
  end

  defp expand(module, caller), do: Macro.expand(module, caller)

  defmacro __using__(opts) do
    codecs =
      opts
      |> Keyword.fetch!(:codecs)
      |> Enum.map(fn {name, module} -> {name, expand(module, __CALLER__)} end)

    declaration = %{
      base_url: Keyword.fetch!(opts, :base_url),
      codecs: codecs,
      auth: expand(Keyword.get(opts, :auth, :none), __CALLER__),
      headers: Keyword.get(opts, :headers, []),
      http: expand(Keyword.get(opts, :http), __CALLER__),
      http_opts: Keyword.get(opts, :http_opts),
      timeout: Keyword.get(opts, :timeout),
      json: expand(Keyword.get(opts, :json), __CALLER__)
    }

    quote do
      @doc "The provider declaration: base URL, auth shape, codecs and seam defaults."
      @spec __provider__() :: map()
      def __provider__, do: unquote(Macro.escape(declaration))

      @doc "Builds a client for this provider. See `LlmCall.Provider.build/2`."
      @spec client(keyword()) :: LlmCall.Client.t()
      def client(opts \\ []), do: LlmCall.Provider.build(__MODULE__, opts)
    end
  end
end
