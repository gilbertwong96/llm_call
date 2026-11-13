defmodule LlmCall.Protocol.Helpers do
  @moduledoc """
  Validation and encoding primitives shared by protocol adapters.

  This is the public adapter-authoring surface: core's reference adapters and
  every adapter package use it, so a change to the error shape, the reserved-key
  rule, or the `capture_raw` policy lands in one place. Reimplementing these in a
  package would produce adapters that `LlmCall.Codec.Conformance` cannot check
  consistently.

  A codec keeps a module attribute for its own name (`@codec :openai_chat`) and
  passes it to `error/2`, `reject/3`, and `validate_options/3`, so every
  validation message is prefixed with the codec that rejected the request.
  """

  alias LlmCall.{Config, Error, StreamEvent}

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
  Builds a `LlmCall.StreamEvent`, applying the `capture_raw` policy.

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
  @spec retryable?(String.t() | nil, [String.t()]) :: boolean()
  def retryable?(code, codes) when is_binary(code), do: code in codes
  def retryable?(nil, _codes), do: false

  @doc """
  The provider payload to retain on a response or media response, or `nil`.

  `:response` and `:all` keep it; `:none` does not.
  """
  @spec capture_response(Config.t(), term()) :: map() | nil
  def capture_response(%Config{capture_raw: raw}, term) when raw in [:response, :all], do: term
  def capture_response(_config, _term), do: nil
end
