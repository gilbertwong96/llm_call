defmodule LlmDialect.Protocol.Helpers do
  @moduledoc """
  Validation and encoding primitives shared by protocol adapters.

  This is the public adapter-authoring surface: core's reference adapters and the
  vendored media adapters call it, so a change to the error shape, the
  reserved-key rule, or the `capture_raw` policy lands in one place.
  Reimplementing these in a package would produce adapters that
  `LlmDialect.Codec.Conformance` cannot check consistently.

  The composite entry points — `encode_completion/6`, `validate_media_request/8`,
  and `validate_parts/3` — are what most adapters call. The individual checks
  (`validate_model/2`, `validate_modalities/3`, `validate_option_map/4`,
  `validate_tool_call_arguments/2`, ...) are public so a codec with an unusual
  pipeline can compose them instead of copying them; only some of them are used
  by every adapter. Four exist for a codec that reimplements a pipeline step:
  `capture_event/2`, `reserved_key?/2`, `validate_modality/3`, and
  `validate_prompt/2`.

  A codec's own name is injected as `@codec` by the adapter macros; pass it to
  `error/2`, `reject/3`, and `validate_options/3`, so every validation message is
  prefixed with the codec that rejected the request.
  """

  alias LlmDialect.{Config, Content, Error, Message, StreamEvent, ToolCall, ToolResult, ToolSpec}

  @type codec :: atom()

  @doc """
  Builds a `:validation` error prefixed with the codec name.

  The single constructor for validation errors, so a package cannot drift on the
  `kind` or the message shape the conformance suite expects.
  """
  @spec error(codec(), String.t()) :: {:error, Error.t()}
  def error(codec, message) do
    {:error, %Error{kind: :validation, message: "#{codec}: " <> message}}
  end

  @doc """
  Returns the first `{:error, _}` a `fun` produces, or `:ok`.

  Validation is written as a pipeline of checks; this preserves the first failure
  instead of reporting the last.
  """
  @spec first_error([term()], (term() -> :ok | {:error, Error.t()})) ::
          :ok | {:error, Error.t()}
  def first_error(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Puts a key unless the value is `nil`.

  Protocol bodies omit absent fields rather than sending JSON nulls.
  """
  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Returns `:ok` for `nil` and a validation error otherwise.

  For canonical fields a protocol has no equivalent for: absent is fine, present
  is refused.
  """
  @spec reject(term(), codec(), String.t()) :: :ok | {:error, Error.t()}
  def reject(nil, _codec, _message), do: :ok
  def reject(_value, codec, message), do: error(codec, message)

  @doc """
  Reports whether a `provider_options` key would replace a canonical field.

  Keys are normalised to strings and downcased, so `%{prompt: "x"}` is caught as
  well as `%{"prompt" => "x"}`.
  """
  @spec reserved_key?(term(), [String.t()]) :: boolean()
  def reserved_key?(key, reserved_keys) when is_binary(key) or is_atom(key) do
    key |> to_string() |> String.downcase() |> then(&(&1 in reserved_keys))
  end

  def reserved_key?(_key, _reserved_keys), do: false

  @doc """
  Checks that a `provider_options` namespace is a map.

  Adapters reject a malformed namespace rather than ignoring it.
  """
  @spec validate_options(term(), codec(), String.t()) :: :ok | {:error, Error.t()}
  def validate_options(options, _codec, _label) when is_map(options), do: :ok
  def validate_options(_options, codec, label), do: error(codec, "#{label} must be a map")

  @doc """
  Builds a `LlmDialect.StreamEvent`, applying the `capture_raw` policy.

  `term` is the provider payload the event came from; it is kept only when
  `capture_raw: :all`.
  """
  @spec event(StreamEvent.type(), StreamEvent.index(), StreamEvent.delta(), term(), Config.t()) ::
          StreamEvent.t()
  def event(type, index, delta, term, config) do
    %StreamEvent{type: type, index: index, delta: delta, raw: capture_event(config, term)}
  end

  @doc """
  The provider event to retain on a `StreamEvent`, or `nil`.

  `capture_raw: :all` keeps every chunk; `:none` and `:response` keep none.
  """
  @spec capture_event(Config.t(), term()) :: map() | nil
  def capture_event(%Config{capture_raw: :all}, term) when is_map(term), do: term
  def capture_event(_config, _term), do: nil

  @doc """
  The retry hint: true when the provider code is in the codec's retryable set.

  Adapters keep their own set — providers name their codes differently — but
  share this rule and its `nil` handling, so the hint means the same thing
  everywhere.
  """
  @spec retryable?(term(), [String.t()]) :: boolean()
  def retryable?(code, codes) when is_binary(code), do: code in codes
  def retryable?(_code, _codes), do: false

  @doc """
  Normalizes a provider error envelope.

  `code_keys` names the fields that may carry the provider's machine code, in
  priority order (OpenAI and Seedance use `code` then `type`, Anthropic `type`,
  Google `status`). `retryable_codes` is the codec's own retryable set.
  """
  @spec decode_provider_error(term(), codec(), [String.t()], [String.t()]) :: Error.t()
  def decode_provider_error(
        %{"error" => %{"message" => message} = error} = payload,
        _codec,
        code_keys,
        retryable_codes
      ) do
    code = code_keys |> Enum.map(&error[&1]) |> Enum.find(&(not is_nil(&1))) |> code()

    %Error{
      kind: :provider,
      message: message,
      code: code,
      status: nil,
      retryable?: retryable?(code, retryable_codes),
      raw: payload
    }
  end

  def decode_provider_error(term, codec, _code_keys, _retryable_codes) do
    %Error{
      kind: :invalid_response,
      message: "#{codec}: unrecognized error payload",
      raw: if(is_map(term), do: term, else: nil)
    }
  end

  @doc """
  Validates a Gemini-style bare model id.

  The model is interpolated into a request path, so a `/` or `:` would build a
  different endpoint than the caller asked for.
  """
  @spec validate_model_id(LlmDialect.model() | nil, codec()) :: :ok | {:error, Error.t()}
  def validate_model_id(model, codec) when is_binary(model) and model != "" do
    if String.contains?(model, ["/", ":"]) do
      error(codec, "model must be a bare model id without \"/\" or \":\"")
    else
      :ok
    end
  end

  def validate_model_id(_model, codec), do: error(codec, "model is required")

  @doc """
  Decodes a provider's raw argument string into a map, or `nil` when it is not an
  object.

  Providers that hand arguments over as a JSON string (Anthropic, some Gemini
  shapes) share this so a malformed fragment never becomes `%{}`.
  """
  @spec decode_raw_arguments(String.t() | nil) :: map() | nil
  def decode_raw_arguments(raw) when is_binary(raw) do
    case :json.decode(raw) do
      %{} = decoded -> decoded
      _not_a_map -> nil
    end
  rescue
    _decode_error -> nil
  end

  def decode_raw_arguments(nil), do: nil

  @doc """
  Builds a `POST` encoded request with no query parameters.
  """
  @spec post(String.t(), [{String.t(), String.t()}], map()) :: LlmDialect.EncodedRequest.t()
  def post(path, headers, body) do
    %LlmDialect.EncodedRequest{
      method: :post,
      path: path,
      query: %{},
      headers: headers,
      body: body
    }
  end

  @doc """
  Validates that a model id is a non-empty string.
  """
  @spec validate_model(LlmDialect.model() | nil, codec()) :: :ok | {:error, Error.t()}
  def validate_model(model, _codec) when is_binary(model) and model != "", do: :ok
  def validate_model(_model, codec), do: error(codec, "model is required")

  @doc """
  Validates canonical messages: a non-empty list of user/assistant turns, each
  with a non-empty content list.
  """
  @spec validate_messages([Message.t()], codec()) :: :ok | {:error, Error.t()}
  def validate_messages([], codec), do: error(codec, "at least one message is required")

  def validate_messages(messages, codec) when is_list(messages) do
    first_error(messages, fn
      %Message{role: role, content: []} when role in [:user, :assistant] ->
        error(codec, "message requires at least one content part")

      %Message{role: role, content: content}
      when role in [:user, :assistant] and is_list(content) ->
        :ok

      %Message{role: role} when role in [:user, :assistant] ->
        error(codec, "message content must be a list")

      %Message{} ->
        error(codec, "message role must be :user or :assistant")

      _other ->
        error(codec, "messages must be LlmDialect.Message structs")
    end)
  end

  def validate_messages(_messages, codec), do: error(codec, "messages must be a list")

  @doc """
  Validates every content part in every message, applying the shared role rules
  before the codec's `shape_fun`.

  Protocol-specific role rules (for example OpenAI rejecting images in assistant
  turns) stay in the codec's own `validate_part/2`.
  """
  @spec validate_parts(
          [Message.t()],
          codec(),
          (Message.role(), Content.part() -> :ok | {:error, Error.t()})
        ) :: :ok | {:error, Error.t()}
  def validate_parts(messages, codec, shape_fun) do
    first_error(messages, fn %Message{role: role, content: content} ->
      first_error(content, &validate_part(role, &1, codec, shape_fun))
    end)
  end

  defp validate_part(role, part, codec, shape_fun) do
    with :ok <- validate_role(role, part, codec), do: shape_fun.(role, part)
  end

  @doc """
  Validates the system field: `nil`, a string, or a list of text parts.
  """
  @spec validate_system(LlmDialect.Request.system(), codec()) :: :ok | {:error, Error.t()}
  def validate_system(nil, _codec), do: :ok
  def validate_system(text, _codec) when is_binary(text), do: :ok

  def validate_system(parts, codec) when is_list(parts) do
    first_error(parts, fn
      %Content.Text{text: text} when is_binary(text) -> :ok
      %Content.Text{} -> error(codec, "system text part requires text")
      _part -> error(codec, "system only supports text parts")
    end)
  end

  def validate_system(_system, codec),
    do: error(codec, "system must be a string or a list of content parts")

  @doc """
  Validates the tool list and delegates the tool-choice rules to the codec.

  `spec_validator` is the codec's `validate_tool_spec/1`; `choice_validator` is
  its `validate_tool_choice/2`, which owns the per-protocol choice union.
  """
  @spec validate_tools(
          [ToolSpec.t()],
          LlmDialect.Request.tool_choice(),
          codec(),
          (ToolSpec.t() -> :ok | {:error, Error.t()}),
          (term(), [ToolSpec.t()] -> :ok | {:error, Error.t()})
        ) ::
          :ok | {:error, Error.t()}
  def validate_tools(tools, tool_choice, _codec, spec_validator, choice_validator)
      when is_list(tools) do
    with :ok <- first_error(tools, spec_validator) do
      choice_validator.(tool_choice, tools)
    end
  end

  def validate_tools(_tools, _tool_choice, codec, _spec_validator, _choice_validator),
    do: error(codec, "tools must be a list")

  @doc """
  Validates a tool call's arguments: a decoded map, or a raw string that decodes
  to an object. A malformed fragment is an error, never `%{}`. A map that cannot
  be JSON-encoded is an error too, because the codec has to emit it as a string.
  """
  @spec validate_tool_call_arguments(ToolCall.t(), codec()) :: :ok | {:error, Error.t()}
  def validate_tool_call_arguments(%ToolCall{arguments: arguments}, codec)
      when is_map(arguments) do
    if LlmDialect.JSON.encodable?(arguments),
      do: :ok,
      else: error(codec, "tool call arguments must be JSON-encodable")
  end

  def validate_tool_call_arguments(%ToolCall{raw_arguments: nil}, _codec), do: :ok

  def validate_tool_call_arguments(%ToolCall{raw_arguments: raw}, codec) do
    case :json.decode(raw) do
      %{} -> :ok
      _not_a_map -> error(codec, "tool call raw_arguments must decode to an object")
    end
  rescue
    _decode_error -> error(codec, "tool call raw_arguments must decode to an object")
  end

  @doc """
  Validates tool-result content: a string or a list of text parts.
  """
  @spec validate_tool_result_content(term(), codec()) :: :ok | {:error, Error.t()}
  def validate_tool_result_content(content, _codec) when is_binary(content), do: :ok

  def validate_tool_result_content(content, codec) when is_list(content) do
    first_error(content, fn
      %Content.Text{} -> :ok
      _part -> error(codec, "tool result only supports text content")
    end)
  end

  def validate_tool_result_content(_content, codec),
    do: error(codec, "tool result content must be a string or content parts")

  @doc """
  Validates a media request's modality.
  """
  @spec validate_modality(term(), :image | :video, codec()) :: :ok | {:error, Error.t()}
  def validate_modality(expected, expected, _codec), do: :ok

  def validate_modality(modality, expected, codec) do
    error(codec, "modality must be #{inspect(expected)}, got: #{inspect(modality)}")
  end

  @doc """
  Runs a media adapter's validation pipeline.

  The shared steps are modality, model, prompt, and the codec's own param,
  reference, and provider-option checks, passed as functions so each codec keeps
  its protocol-specific rules.
  """
  @spec validate_media_request(
          LlmDialect.Media.Request.t(),
          Config.t(),
          codec(),
          :image | :video,
          (LlmDialect.model() | nil, codec() -> :ok | {:error, Error.t()}),
          (map() -> :ok | {:error, Error.t()}),
          (term() -> :ok | {:error, Error.t()}),
          (LlmDialect.Media.Request.t(), Config.t() -> :ok | {:error, Error.t()})
        ) :: :ok | {:error, Error.t()}
  def validate_media_request(
        request,
        config,
        codec,
        modality,
        model_fun,
        params_fun,
        references_fun,
        options_fun
      ) do
    with :ok <- validate_modality(request.modality, modality, codec),
         :ok <- model_fun.(request.model, codec),
         :ok <- validate_prompt(request.prompt, codec),
         :ok <- params_fun.(request.params),
         :ok <- references_fun.(request.references) do
      options_fun.(request, config)
    end
  end

  @doc """
  Validates that a media prompt is a non-empty string.
  """
  @spec validate_prompt(String.t() | nil, codec()) :: :ok | {:error, Error.t()}
  def validate_prompt(prompt, _codec) when is_binary(prompt) and prompt != "", do: :ok
  def validate_prompt(_prompt, codec), do: error(codec, "prompt is required")

  @doc """
  Validates `params.n` against the codec's declared maximum.
  """
  @spec validate_n(pos_integer() | nil, pos_integer() | :unsupported, codec()) ::
          :ok | {:error, Error.t()}
  def validate_n(nil, _max_n, _codec), do: :ok
  def validate_n(_n, :unsupported, codec), do: error(codec, "params.n is not supported")
  def validate_n(n, max_n, _codec) when is_integer(n) and n > 0 and n <= max_n, do: :ok
  def validate_n(_n, max_n, codec), do: error(codec, "params.n must be between 1 and #{max_n}")

  @doc """
  Validates that a content part may appear in that role.

  Tool calls and thinking belong to assistant turns, tool results to user turns;
  everything else is the protocol's business.
  """
  @spec validate_role(Message.role(), LlmDialect.Content.part(), codec()) ::
          :ok | {:error, Error.t()}
  def validate_role(:user, %ToolCall{}, codec),
    do: error(codec, "tool calls belong to assistant messages")

  def validate_role(:user, %Content.Thinking{}, codec),
    do: error(codec, "thinking content belongs to assistant messages")

  def validate_role(:assistant, %ToolResult{}, codec),
    do: error(codec, "tool results belong to user messages")

  def validate_role(_role, _part, _codec), do: :ok

  @doc """
  Validates then encodes a completion request as a `POST` with no query.
  """
  @spec encode_completion(
          LlmDialect.Request.t(),
          Config.t(),
          String.t(),
          [{String.t(), String.t()}],
          (LlmDialect.Request.t(), Config.t() -> :ok | {:error, Error.t()}),
          (LlmDialect.Request.t(), Config.t() -> map())
        ) :: {:ok, LlmDialect.EncodedRequest.t()} | {:error, Error.t()}
  def encode_completion(request, config, path, headers, validate_fun, body_fun) do
    with :ok <- validate_fun.(request, config) do
      {:ok, post(path, headers, body_fun.(request, config))}
    end
  end

  @doc """
  Validates the requested output modalities.

  `allowed` is the protocol's output surface: OpenAI Chat and Anthropic accept
  text only, Gemini also accepts images. Anything outside `[:text, :image,
  :video]` or duplicated is a structural error.
  """
  @spec validate_modalities([LlmDialect.modality()], [LlmDialect.modality()], codec()) ::
          :ok | {:error, Error.t()}
  def validate_modalities(modalities, allowed, codec)
      when is_list(modalities) and modalities != [] do
    cond do
      Enum.any?(modalities, &(&1 not in [:text, :image, :video])) ->
        error(codec, "modality must be :text, :image or :video")

      length(Enum.uniq(modalities)) != length(modalities) ->
        error(codec, "modalities must not repeat a value")

      Enum.any?(modalities, &(&1 not in allowed)) ->
        unsupported = Enum.reject(modalities, &(&1 in allowed))
        error(codec, "output modality #{inspect(unsupported)} is not supported")

      true ->
        :ok
    end
  end

  def validate_modalities(_modalities, _allowed, codec),
    do: error(codec, "modalities must be a non-empty list")

  @doc """
  Validates that `params` is a map and only contains supported keys.
  """
  @spec validate_params(term(), [atom()], codec()) :: :ok | {:error, Error.t()}
  def validate_params(params, keys, codec) when is_map(params),
    do: validate_param_keys(params, keys, codec)

  def validate_params(_params, _keys, codec), do: error(codec, "params must be a map")

  @doc """
  Validates a tool spec.

  `strict: true` lets the protocol forward `strict`; otherwise a non-nil value is
  rejected. `options: true` lets the protocol forward `provider_options`.
  """
  @spec validate_tool_spec(ToolSpec.t(), codec(), keyword()) :: :ok | {:error, Error.t()}
  def validate_tool_spec(%ToolSpec{kind: :builtin}, codec, _opts),
    do: error(codec, "builtin tools are not supported")

  def validate_tool_spec(%ToolSpec{name: name} = spec, codec, opts)
      when is_binary(name) and name != "" do
    strict =
      if Keyword.get(opts, :strict, false),
        do: :ok,
        else: reject(spec.strict, codec, "tool strict mode is not supported")

    options =
      if Keyword.get(opts, :options, false),
        do: validate_options(spec.provider_options, codec, "tool provider_options"),
        else: :ok

    with :ok <- strict do
      options
    end
  end

  def validate_tool_spec(%ToolSpec{}, codec, _opts),
    do: error(codec, "function tool requires a name")

  def validate_tool_spec(_spec, codec, _opts),
    do: error(codec, "tools must be LlmDialect.ToolSpec structs")

  @doc """
  Validates that a `params` map only contains supported keys.

  A `nil` value means "provider default" and is ignored; an unsupported key with
  a value is a validation error, never a silent drop.
  """
  @spec validate_param_keys(map(), [atom()], codec()) :: :ok | {:error, Error.t()}
  def validate_param_keys(params, allowed_keys, codec) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map(fn {key, _value} -> key end)
    |> first_error(fn key ->
      if key in allowed_keys,
        do: :ok,
        else: error(codec, "params key #{inspect(key)} is not supported")
    end)
  end

  @doc """
  Validates that a provider-options namespace only contains keys a codec can
  forward without replacing a canonical field.
  """
  @spec validate_option_keys(map(), [String.t()], codec()) :: :ok | {:error, Error.t()}
  def validate_option_keys(options, reserved_keys, codec) when is_map(options) do
    options
    |> Map.keys()
    |> first_error(fn key ->
      cond do
        not is_binary(key) ->
          error(codec, "provider option key #{inspect(key)} must be a string")

        reserved_key?(key, reserved_keys) ->
          error(codec, "provider option #{inspect(key)} would replace a canonical field")

        true ->
          :ok
      end
    end)
  end

  def validate_option_keys(_options, _reserved_keys, codec),
    do: error(codec, "provider options must be a map")

  @doc """
  Collapses an alias namespace into its primary and deep-merges the two sources.

  Gemini accepts both `:gemini` and its `:google` alias, and each source may use
  either spelling. Collapsing per source before merging keeps the documented
  rule — a request value wins over a config default — even when the two disagree
  on the name, and deep-merging lets a request extend a defaulted native object
  instead of replacing it.
  """
  @spec alias_options(map(), map(), atom(), atom()) :: map()
  def alias_options(defaults, request, primary, alias) do
    defaults
    |> collapse_alias(primary, alias)
    |> Config.deep_merge(collapse_alias(request, primary, alias))
  end

  defp collapse_alias(options, primary, alias) do
    case {Map.get(options, primary), Map.get(options, alias)} do
      {nil, nil} -> %{}
      {primary_value, nil} -> primary_value
      {nil, alias_value} -> alias_value
      {primary_value, alias_value} -> Config.deep_merge(alias_value, primary_value)
    end
  end

  @doc """
  Validates a provider-options container against the namespaces a codec consumes.

  Three things must hold, or the caller would get a valid-looking request whose
  options are silently ignored or would raise later:

    * the container is a map;
    * every key is an atom, and with `strict?: true` one the codec reads
      (`:openai`, `[:gemini, :google]`, ...) — a typo or a string key is an error,
      not a drop;
    * every present declared namespace holds a map, so
      `LlmDialect.Config.deep_merge/2` is never handed a non-map.

  Pass `strict?: false` for `Config.default_provider_options`: a default map is
  application-wide and legitimately carries namespaces for other providers, so
  only the namespaces this codec reads are checked.
  """
  @spec validate_option_map(term(), codec(), String.t(), [atom()], keyword()) ::
          :ok | {:error, Error.t()}
  def validate_option_map(options, codec, label, namespaces, opts \\ [])

  def validate_option_map(options, codec, label, namespaces, opts) when is_map(options) do
    strict? = Keyword.get(opts, :strict?, true)

    options
    |> Map.keys()
    |> first_error(fn key -> validate_namespace_key(key, namespaces, codec, label, strict?) end)
    |> then(fn
      :ok -> validate_namespace_values(options, namespaces, codec, label)
      error -> error
    end)
  end

  def validate_option_map(_options, codec, label, _namespaces, _opts),
    do: error(codec, "#{label} must be a map")

  defp validate_namespace_key(key, namespaces, codec, label, strict?) do
    cond do
      not is_atom(key) ->
        error(codec, "#{label} namespace #{inspect(key)} must be an atom")

      strict? and key not in namespaces ->
        error(
          codec,
          "#{label} namespace #{inspect(key)} is not used by this codec " <>
            "(expected #{inspect(namespaces)})"
        )

      true ->
        :ok
    end
  end

  defp validate_namespace_values(options, namespaces, codec, label) do
    first_error(namespaces, fn key ->
      case Map.fetch(options, key) do
        :error -> :ok
        {:ok, value} when is_map(value) and not is_struct(value) -> :ok
        {:ok, _other} -> error(codec, "#{label}.#{key} must be a map")
      end
    end)
  end

  @doc """
  Normalizes a provider's error code to a string or `nil`.

  Providers type this field inconsistently (a string for OpenAI and Google, an
  integer for MiniMax); `LlmDialect.Error.code` is always a string so callers can
  compare it without type juggling.
  """
  @spec code(term()) :: String.t() | nil
  def code(value) when is_binary(value), do: value
  def code(value) when is_integer(value), do: Integer.to_string(value)
  def code(_value), do: nil

  @doc """
  The provider payload to retain on a response or media response, or `nil`.

  `:response` and `:all` keep it; `:none` does not.
  """
  @spec capture_response(Config.t(), term()) :: map() | nil
  def capture_response(%Config{capture_raw: raw}, term) when raw in [:response, :all], do: term
  def capture_response(_config, _term), do: nil
end
