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

  `http_opts` and `timeout` may be declared here, and each resolves call option →
  provider → `config :llm_call, ...` → built-in default. A declaration that omits
  them leaves the value `nil`, so the application setting still applies.

  `json_library` resolves call option → provider → the compile-time application
  default (`Application.compile_env(:llm_call, :json_library, JSON)`). It is
  written into the client's `%LlmCall.Config{}`, so the codecs use the same
  implementation as the transport. A `config:` call option supplies the base
  config; a `json_library:` call option still wins over it, and the declaration's
  `json_library:` applies only when the caller passes neither.
  """

  alias LlmCall.{Client, Config}
  alias LlmCall.HTTP

  @default_timeout 60_000

  @client_option_keys [
    :api_key,
    :base_url,
    :headers,
    :http_opts,
    :timeout,
    :json_library,
    :config
  ]

  @doc """
  Builds a `%LlmCall.Client{}` from a provider module's declaration and options.

  Options: `api_key:`, `base_url:`, `headers:`, `http_opts:`, `timeout:`,
  `json_library:`, `config:`.
  """
  @spec build(module(), keyword()) :: Client.t()
  def build(provider, opts \\ []) do
    validate_build_options!(opts)
    declaration = provider.__provider__()

    config =
      opts
      |> base_config(declaration)
      |> put_json(json_option(opts, declaration))

    %Client{
      provider: provider,
      codecs: Map.new(declaration.codecs),
      base_url: validate_base_url!(opts[:base_url] || declaration.base_url),
      headers: headers(declaration, opts),
      http_opts: resolve(:http_opts, opts, declaration, []) |> validate_http_opts!(),
      timeout: resolve(:timeout, opts, declaration, @default_timeout) |> validate_timeout!(),
      config: config
    }
  end

  defp headers(declaration, opts) do
    caller = Keyword.get(opts, :headers, []) || []
    auth = auth_headers(declaration.auth, opts[:api_key])

    validate_headers!(caller, "client option :headers")
    validate_headers!(declaration.headers, "provider headers")
    validate_headers!(auth, "auth headers")

    HTTP.merge_headers([auth, declaration.headers, caller])
  end

  defp validate_build_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "client options must be a keyword list"
    end

    case Keyword.keys(opts) -- @client_option_keys do
      [] -> :ok
      [unknown | _] -> raise ArgumentError, "unknown option #{inspect(unknown)}"
    end
  end

  defp validate_headers!(headers, label) do
    unless HTTP.valid_headers?(headers) do
      raise ArgumentError, "#{label} must be a list of {name, value} string tuples"
    end
  end

  @http_timeout_keys [:pool_timeout, :receive_timeout, :request_timeout]

  defp validate_http_opts!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "client option :http_opts must be a keyword list"
    end

    Enum.each(opts, &validate_http_opt!/1)
    opts
  end

  defp validate_http_opt!({key, value}) when key in @http_timeout_keys do
    unless value == :infinity or (is_integer(value) and value > 0) do
      raise ArgumentError,
            "client option :http_opts #{inspect(key)} must be a positive integer or :infinity, " <>
              "got: #{inspect(value)}"
    end
  end

  defp validate_http_opt!({:name, value}) do
    unless is_atom(value) and not is_nil(value) do
      raise ArgumentError,
            "client option :http_opts :name must be a pool name atom, got: #{inspect(value)}"
    end
  end

  defp validate_http_opt!({:pool_strategy, value})
       when value in [:random, :ordered] or is_integer(value) or is_function(value, 2),
       do: :ok

  defp validate_http_opt!({:pool_strategy, value}) do
    raise ArgumentError,
          "client option :http_opts :pool_strategy must be :random, :ordered, an integer, " <>
            "or a 2-arity function, got: #{inspect(value)}"
  end

  defp validate_http_opt!(_entry), do: :ok

  defp validate_timeout!(:infinity), do: :infinity

  defp validate_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_timeout!(timeout) do
    raise ArgumentError,
          "client option :timeout must be a positive integer or :infinity, got: #{inspect(timeout)}"
  end

  defp validate_base_url!(url) when is_binary(url) and url != "", do: url

  defp validate_base_url!(url) do
    raise ArgumentError,
          "client option :base_url must be a non-empty string, got: #{inspect(url)}"
  end

  defp validate_json_library!(nil), do: nil
  defp validate_json_library!(module) when is_atom(module), do: module

  defp validate_json_library!(module) do
    raise ArgumentError, "client option :json_library must be a module, got: #{inspect(module)}"
  end

  defp resolve(key, opts, declaration, default) do
    opts[key] || declaration[key] || app_env(key) || default
  end

  defp base_config(opts, _declaration) do
    case Keyword.get(opts, :config) do
      nil ->
        Config.new()

      %Config{} = config ->
        config

      other ->
        raise ArgumentError,
              "client option :config must be a %LlmCall.Config{}, got: #{inspect(other)}"
    end
  end

  defp json_option(opts, declaration) do
    call = opts[:json_library]
    json = if Keyword.has_key?(opts, :config), do: call, else: call || declaration[:json_library]
    validate_json_library!(json)
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

  defp validate_auth!(:none), do: :ok
  defp validate_auth!(:bearer), do: :ok
  defp validate_auth!(:x_api_key), do: :ok

  defp validate_auth!({:header, name}) when is_binary(name) and name != "", do: :ok

  defp validate_auth!({module, function}) when is_atom(module) and is_atom(function), do: :ok

  defp validate_auth!(auth) do
    raise ArgumentError,
          "provider option :auth must be :none, :bearer, :x_api_key, " <>
            "{:header, name}, or {module, function}, got: #{inspect(auth)}"
  end

  defp validate_codec_names!(codecs) do
    Enum.each(codecs, fn
      {name, _module} when is_atom(name) ->
        :ok

      {name, _module} ->
        raise ArgumentError, "provider codec names must be atoms, got: #{inspect(name)}"
    end)
  end

  defmacro __using__(opts) do
    codecs =
      opts
      |> Keyword.fetch!(:codecs)
      |> Enum.map(fn {name, module} -> {name, expand(module, __CALLER__)} end)

    validate_codec_names!(codecs)

    if Enum.uniq_by(codecs, &elem(&1, 0)) != codecs do
      raise ArgumentError, "provider declares the same codec name twice: #{inspect(codecs)}"
    end

    base_url = required_literal!(opts, :base_url, __CALLER__)
    headers = literal!(opts, :headers, __CALLER__, []) || []
    http_opts = literal!(opts, :http_opts, __CALLER__, nil)
    timeout = literal!(opts, :timeout, __CALLER__, nil)
    auth = literal!(opts, :auth, __CALLER__, :none)
    json_library = literal!(opts, :json_library, __CALLER__, nil)

    unless is_binary(base_url) and base_url != "" do
      raise ArgumentError,
            "provider option :base_url must be a string (non-empty), got: #{inspect(base_url)}"
    end

    unless is_list(headers) and HTTP.valid_headers?(headers) do
      raise ArgumentError, "provider option :headers must be a list of string pairs"
    end

    unless is_nil(http_opts) or Keyword.keyword?(http_opts) do
      raise ArgumentError, "provider option :http_opts must be a keyword list"
    end

    unless is_nil(timeout) or (is_integer(timeout) and timeout > 0) or timeout == :infinity do
      raise ArgumentError,
            "provider option :timeout must be a positive integer or :infinity, got: #{inspect(timeout)}"
    end

    validate_auth!(auth)
    validate_json_library!(json_library)

    declaration = %{
      base_url: base_url,
      codecs: codecs,
      auth: auth,
      headers: headers,
      http_opts: http_opts,
      timeout: timeout,
      json_library: json_library
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
