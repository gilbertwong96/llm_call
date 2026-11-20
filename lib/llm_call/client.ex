defmodule LlmCall.Client do
  @moduledoc """
  A provider, resolved for calling.

  Built by a provider module's `client/1`, which turns the declaration plus the
  call options into concrete values: endpoint, headers (including auth), query
  parameters, transport options, timeout, and the `%LlmCall.Config{}` the codecs
  receive.

  The client holds **no selected codec**: `codecs` is the provider's map, and each
  call names one (`codec: :chat` by default for `complete/3` and `stream/3`).

  Values are materialised at build time, so changing `config :llm_call` afterwards
  does not mutate an existing client; build a new one.

  ## Timeout

  `timeout` is the **read** timeout, handed to Finch as `:receive_timeout`: each
  body chunk must arrive within it, but it is not a deadline for the whole call.
  A large response on a slow link, or a provider that keeps sending, can outlast
  it. For a wall-clock cap, pass Finch's total timeout through `http_opts:
  [request_timeout: ...]`; on a streaming call it is checked between reads, so
  the effective bound is `request_timeout` plus one `timeout`.
  """

  alias LlmCall.Config

  @type t :: %__MODULE__{
          provider: module(),
          codecs: %{atom() => module()},
          base_url: String.t(),
          headers: [{String.t(), String.t()}],
          query: %{optional(String.t()) => String.t() | integer() | boolean()},
          http_opts: keyword(),
          timeout: timeout(),
          config: Config.t()
        }

  defstruct [
    :provider,
    :codecs,
    :base_url,
    :timeout,
    :config,
    headers: [],
    query: %{},
    http_opts: []
  ]

  @doc "The codec registered under `name`, or `nil`."
  @spec codec(t(), atom()) :: module() | nil
  def codec(%__MODULE__{codecs: codecs}, name), do: Map.get(codecs, name)

  @doc "The codec registered under `name`; raises when the provider does not declare it."
  @spec codec!(t(), atom()) :: module()
  def codec!(%__MODULE__{} = client, name) do
    case codec(client, name) do
      nil ->
        raise ArgumentError,
              "#{inspect(client.provider)} does not declare a #{inspect(name)} codec; " <>
                "declared: #{inspect(Map.keys(client.codecs))}"

      codec ->
        codec
    end
  end
end
