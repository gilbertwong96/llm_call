defmodule LlmCall.Provider do
  @moduledoc """
  Declares a provider: where it lives, how it authenticates, and which codecs it
  serves.

      defmodule MyApp.OpenAI do
        use LlmCall.Provider,
          base_url: "https://api.openai.com",
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

  `base_url` is the origin: every codec path starts with its own version segment
  (`/v1/chat/completions`, `/v1beta/models/...`), so a provider whose base URL
  already ends in `/v1` would produce `/v1/v1/...`.

  Declaration values are literals: `use` receives its options before the module
  body runs, so `base_url: @url` or `base_url: Application.fetch_env!(...)` is a
  compile error. Read a dynamic value where it is known instead —
  `MyProvider.client(api_key: key, base_url: System.fetch_env!("OPENAI_URL"))` —
  or set `config :llm_call, ...`.

  ## Resolution

  `http_opts`, `json_library` and `timeout` may be declared here, and each
  resolves call option → provider → `config :llm_call, ...` → built-in default. The
  JSON module is written into the client's `%LlmCall.Config{}`, so the codecs use
  the same implementation as the transport. A `config:` call option supplies the
  base config; a `json_library:` call option still wins over it, and the
  declaration's `json_library:` applies only when the caller passes neither.
  """

  alias LlmCall.{Client, Config}
  alias LlmCall.HTTP

  @default_timeout 60_000

  @doc """
  Builds a `%LlmCall.Client{}` from a provider module's declaration and options.

  Options: `api_key:`, `base_url:`, `headers:`, `http_opts:`, `timeout:`,
  `json_library:`, `config:`.
  """
  @spec build(module(), keyword()) :: Client.t()
  def build(provider, opts \\ []) do
    declaration = provider.__provider__()

    config =
      opts
      |> base_config(declaration)
      |> put_json(json_option(opts, declaration))

    %Client{
      provider: provider,
      codecs: Map.new(declaration.codecs),
      base_url: opts[:base_url] || declaration.base_url,
      headers: headers(declaration, opts),
      http_opts: resolve(:http_opts, opts, declaration, []),
      timeout: resolve(:timeout, opts, declaration, @default_timeout),
      config: config
    }
  end

  defp headers(declaration, opts) do
    caller = Keyword.get(opts, :headers, []) || []

    unless is_list(caller) do
      raise ArgumentError, "client option :headers must be a list, got: #{inspect(caller)}"
    end

    HTTP.merge_headers([
      auth_headers(declaration.auth, opts[:api_key]),
      declaration.headers,
      caller
    ])
  end

  defp resolve(key, opts, declaration, default) do
    opts[key] || declaration[key] || app_env(key) || default
  end

  defp base_config(opts, _declaration), do: opts[:config] || Config.new()

  defp json_option(opts, declaration) do
    call = opts[:json_library]
    if Keyword.has_key?(opts, :config), do: call, else: call || declaration[:json_library]
  end

  defp put_json(config, nil), do: config
  defp put_json(%Config{} = config, json), do: %{config | json: json}

  defp app_env(key), do: Application.get_env(:llm_call, key)

  defp auth_headers(:none, _key), do: []

  defp auth_headers(:bearer, key), do: [{"authorization", "Bearer #{require_key(key)}"}]
  defp auth_headers(:x_api_key, key), do: [{"x-api-key", require_key(key)}]
  defp auth_headers({:header, name}, key), do: [{name, require_key(key)}]

  defp auth_headers({module, function}, key) when is_atom(module) and is_atom(function) do
    apply(module, function, [require_key(key)])
  end

  defp require_key(nil) do
    raise ArgumentError, "api_key is required by this provider's auth"
  end

  defp require_key(key) when is_binary(key), do: key

  defp require_key(other) do
    raise ArgumentError, "api_key must be a string, got: #{inspect(other)}"
  end

  defp required_literal!(opts, key, caller) do
    literal!(opts, key, caller, :missing)
  end

  defp literal!(opts, key, caller, default) do
    case Keyword.fetch(opts, key) do
      :error ->
        default

      {:ok, value} ->
        expanded = Macro.prewalk(value, &Macro.expand(&1, caller))

        unless Macro.quoted_literal?(expanded) do
          raise ArgumentError,
                "provider option #{inspect(key)} must be a literal value; " <>
                  "got: #{Macro.to_string(value)}"
        end

        expanded
    end
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

    if Enum.uniq_by(codecs, &elem(&1, 0)) != codecs do
      raise ArgumentError, "provider declares the same codec name twice: #{inspect(codecs)}"
    end

    base_url = required_literal!(opts, :base_url, __CALLER__)
    headers = literal!(opts, :headers, __CALLER__, []) || []
    http_opts = literal!(opts, :http_opts, __CALLER__, []) || []
    timeout = literal!(opts, :timeout, __CALLER__, nil)

    unless is_binary(base_url) do
      raise ArgumentError, "provider option :base_url must be a string, got: #{inspect(base_url)}"
    end

    unless is_list(headers), do: raise(ArgumentError, "provider option :headers must be a list")

    unless is_list(http_opts),
      do: raise(ArgumentError, "provider option :http_opts must be a list")

    unless is_nil(timeout) or is_integer(timeout) or timeout == :infinity do
      raise ArgumentError,
            "provider option :timeout must be a positive integer or :infinity, got: #{inspect(timeout)}"
    end

    declaration = %{
      base_url: base_url,
      codecs: codecs,
      auth: expand(Keyword.get(opts, :auth, :none), __CALLER__),
      headers: headers,
      http_opts: http_opts,
      timeout: timeout,
      json_library: expand(Keyword.get(opts, :json_library), __CALLER__)
    }

    quote do
      @doc "The provider declaration: base URL, auth shape, codecs and defaults."
      @spec __provider__() :: map()
      def __provider__, do: unquote(Macro.escape(declaration))

      @doc "Builds a client for this provider. See `LlmCall.Provider.build/2`."
      @spec client(keyword()) :: LlmCall.Client.t()
      def client(opts \\ []), do: LlmCall.Provider.build(__MODULE__, opts)
    end
  end
end
