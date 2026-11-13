defmodule LlmCall.Protocol.Helpers do
  @moduledoc false

  # Validation and encoding primitives every protocol adapter needs. Kept out of
  # the codecs so a change to the error shape or the capture policy lands once.

  alias LlmCall.{Config, Error, StreamEvent}

  @type codec :: atom()

  @spec error(codec(), String.t()) :: {:error, Error.t()}
  def error(codec, message) do
    {:error, %Error{kind: :validation, message: "#{codec}: " <> message}}
  end

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

  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec reject(term(), codec(), String.t()) :: :ok | {:error, Error.t()}
  def reject(nil, _codec, _message), do: :ok
  def reject(_value, codec, message), do: error(codec, message)

  @spec reserved_key?(term(), [String.t()]) :: boolean()
  def reserved_key?(key, reserved_keys) do
    key |> to_string() |> String.downcase() |> then(&(&1 in reserved_keys))
  end

  @spec validate_options(term(), codec(), String.t()) :: :ok | {:error, Error.t()}
  def validate_options(options, _codec, _label) when is_map(options), do: :ok
  def validate_options(_options, codec, label), do: error(codec, "#{label} must be a map")

  @spec event(StreamEvent.type(), StreamEvent.index(), StreamEvent.delta(), term(), Config.t()) ::
          StreamEvent.t()
  def event(type, index, delta, term, config) do
    %StreamEvent{type: type, index: index, delta: delta, raw: capture_event(config, term)}
  end

  @spec capture_event(Config.t(), term()) :: map() | nil
  def capture_event(%Config{capture_raw: :all}, term) when is_map(term), do: term
  def capture_event(_config, _term), do: nil

  @spec capture_response(Config.t(), term()) :: map() | nil
  def capture_response(%Config{capture_raw: raw}, term) when raw in [:response, :all], do: term
  def capture_response(_config, _term), do: nil
end
