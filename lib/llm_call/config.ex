defmodule LlmCall.Config do
  @moduledoc """
  Codec defaults and capture policy.

  Holds no credentials and no base URL: those belong to the transport.
  `default_provider_options` is merged before a request's `provider_options`
  (completion or media), and the request wins per key.
  """

  @type t :: %__MODULE__{
          default_provider_options: map(),
          capture_raw: LlmCall.capture_raw(),
          json: module()
        }

  @default_json Application.compile_env(:llm_call, :json_library, JSON)

  defstruct default_provider_options: %{}, capture_raw: :none, json: @default_json

  @doc """
  Builds a config from the compile-time JSON default.

  `json_library:` overrides the compiled default per config. The default is
  Elixir's built-in `JSON`. Any module exposing either tagged
  `encode/1`/`decode/1` (Torque, Jason, Poison) or bang `encode!/1`/`decode!/1`
  (Elixir `JSON`) can be configured; `LlmCall.JSON` normalizes both to tagged
  tuples.
  """
  @option_keys [:json_library, :capture_raw, :default_provider_options]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "config options must be a keyword list"
    end

    case Keyword.keys(opts) -- @option_keys do
      [] -> :ok
      [unknown | _] -> raise ArgumentError, "unknown option #{inspect(unknown)}"
    end

    json = Keyword.get(opts, :json_library, @default_json)
    capture_raw = Keyword.get(opts, :capture_raw, :none)
    default_provider_options = Keyword.get(opts, :default_provider_options, %{})

    unless is_atom(json) and not is_nil(json) do
      raise ArgumentError, "config option :json_library must be a module"
    end

    unless capture_raw in [:none, :response, :all] do
      raise ArgumentError, "config option :capture_raw must be :none, :response or :all"
    end

    unless is_map(default_provider_options) do
      raise ArgumentError, "config option :default_provider_options must be a map"
    end

    %__MODULE__{
      json: json,
      capture_raw: capture_raw,
      default_provider_options: default_provider_options
    }
  end

  @doc """
  Deep-merges native provider options over a canonical body.

  Nested maps merge recursively, so a native `generationConfig` keeps the
  canonical `temperature`. Lists and scalars from the native side replace the
  canonical value.
  """
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(canonical, native) when is_map(canonical) and is_map(native) do
    Map.merge(canonical, native, fn _key, left, right ->
      if is_map(left) and is_map(right), do: deep_merge(left, right), else: right
    end)
  end

  def deep_merge(canonical, native) do
    raise ArgumentError,
          "deep_merge/2 expects two maps, got: #{inspect(canonical)} and #{inspect(native)}"
  end

  @doc """
  Merged provider options for a request, keyed by provider namespace.

  Namespaces present in both the config and the request are merged per key, with
  the request value winning.
  """
  @spec provider_options(LlmCall.Request.t() | LlmCall.Media.Request.t(), t()) :: map()
  def provider_options(%{provider_options: request_options}, %__MODULE__{
        default_provider_options: default_options
      }) do
    Map.merge(default_options, request_options, fn _namespace, defaults, request ->
      if is_map(defaults) and is_map(request) do
        Map.merge(defaults, request)
      else
        request
      end
    end)
  end
end
