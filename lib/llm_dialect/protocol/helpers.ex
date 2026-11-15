defmodule LlmDialect.Protocol.Helpers do
  @moduledoc """
  Validation and encoding primitives shared by protocol adapters.

  This is the public adapter-authoring surface: core's reference adapters and
  every adapter package use it, so a change to the error shape, the reserved-key
  rule, or the `capture_raw` policy lands in one place. Reimplementing these in a
  package would produce adapters that `LlmDialect.Codec.Conformance` cannot check
  consistently.

  A codec keeps a module attribute for its own name (`@codec :openai_chat`) and
  passes it to `error/2`, `reject/3`, and `validate_options/3`, so every
  validation message is prefixed with the codec that rejected the request.
  """

  alias LlmDialect.{Config, Error, StreamEvent}

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
  def reserved_key?(key, reserved_keys) do
    key |> to_string() |> String.downcase() |> then(&(&1 in reserved_keys))
  end

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

  def decode_provider_error(_term, codec, _code_keys, _retryable_codes) do
    %Error{kind: :invalid_response, message: "#{codec}: unrecognized error payload", raw: nil}
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
  def validate_option_keys(options, reserved_keys, codec) do
    options
    |> Map.keys()
    |> first_error(fn key ->
      if reserved_key?(key, reserved_keys),
        do: error(codec, "provider option #{inspect(key)} would replace a canonical field"),
        else: :ok
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
