defmodule LlmCall.Config do
  @moduledoc """
  Codec defaults and capture policy.

  Holds no credentials and no base URL: those belong to the transport.
  `default_provider_options` is merged before a request's `provider_options`
  (completion or media), and the request wins per key.
  """

  @type t :: %__MODULE__{
          default_provider_options: map(),
          capture_raw: LlmCall.capture_raw()
        }

  defstruct default_provider_options: %{}, capture_raw: :none

  @doc """
  Deep-merges native provider options over a canonical body.

  Nested maps merge recursively, so a native `generationConfig` keeps the
  canonical `temperature`. Lists and scalars from the native side replace the
  canonical value.
  """
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(canonical, native) do
    Map.merge(canonical, native, fn _key, left, right ->
      if is_map(left) and is_map(right), do: deep_merge(left, right), else: right
    end)
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
