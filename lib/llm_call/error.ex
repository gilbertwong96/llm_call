defmodule LlmCall.Error do
  @moduledoc """
  A codec error.

  `retryable?` is a hint, not a retry policy. It comes from two signals: the
  codec's verdict on the provider's own code or status field, and the HTTP status
  (`retryable_status?/1`). The client takes the union, because a provider that
  introduces a new code — or a proxy that answers with its own body — must not
  turn a `429` into "do not retry". `kind` says where the error came from. A codec
  produces `:validation`, `:invalid_response` or `:provider`, and the client
  produces the same kinds for its own failures — an unencodable body or an
  undeclared codec name is `:validation`, a `2xx` body that is not JSON is
  `:invalid_response`. `:transport` is a failure below the protocol: no response at
  all, a response that never completed, or a non-`2xx` status. `execute/2`,
  `fetch/2` and a non-`2xx` stream therefore report `:transport` for a response the
  provider *did* send, so `status` is set there and the codec still decoded the
  body when it could.

  `retry_after_ms` is the parsed `Retry-After` header, when the transport saw
  one; it is a hint, not a retry policy.

  `raw` is the provider payload the error was decoded from, and it follows
  `LlmCall.Config.capture_raw` like every other `raw`: it is `nil` unless the
  policy is `:response` or `:all`.

  `code` is the provider's machine-readable code as a string (OpenAI's `code`,
  Anthropic's error type, Google's status such as `"RESOURCE_EXHAUSTED"`,
  MiniMax's numeric code stringified). `status` is the HTTP status, and **only the
  client sets it**: a codec never sees the response status, so it always leaves
  it `nil`.

  `reason` is the structured counterpart of a `:transport` message, and only the
  client sets it. Match on it instead of the message. The library produces:

    * `{:unknown_pool, name}` — the configured Finch pool is not running;
    * `:exception` — the HTTP transport raised;
    * `:disconnected` — the Responses WebSocket is not connected;
    * `{:interrupted, why}` — an in-flight WebSocket lane was dropped
      (`:reconnected`, `:max_age`, `{:unroutable_event, :stream_id_not_echoed}`,
      or the close reason);
    * `{:connection_exited, why}` — the WebSocket connection process ended;
    * the transport's own reason otherwise (`:econnrefused`, `:timeout`,
      `:closed`, `:nxdomain`, `{:tls_alert, ...}`).

  A codec leaves it `nil`, and so does any failure that has a `status`.
  """

  @typedoc """
  A structured transport reason, or `nil` when the failure has none.

  An atom or a tuple; the module documentation lists the values this library
  produces and the transport reasons it passes through. Only `kind: :transport`
  sets it.
  """
  @type reason :: atom() | tuple() | nil

  @type t :: %__MODULE__{
          kind: :validation | :invalid_response | :provider | :transport,
          message: String.t(),
          code: String.t() | nil,
          status: non_neg_integer() | nil,
          reason: reason(),
          retryable?: boolean(),
          retry_after_ms: non_neg_integer() | nil,
          raw: map() | nil
        }

  defstruct kind: nil,
            message: nil,
            code: nil,
            status: nil,
            reason: nil,
            retryable?: false,
            retry_after_ms: nil,
            raw: nil

  @retryable_statuses [408, 425, 429, 500, 502, 503, 504]

  @doc """
  Whether an HTTP status is worth retrying on its own.

  Used two ways: as the whole hint for a `:transport` error that carries no
  provider verdict, and as the second input when a decoded error's status is
  filled in. A provider adding a new rate-limit code must not make a `429` look
  permanent, and the reverse — retrying a `413` — stays out because it is not in
  the list.
  """
  @spec retryable_status?(non_neg_integer() | nil) :: boolean()
  def retryable_status?(status), do: status in @retryable_statuses

  @doc false
  @spec from_transport(term()) :: t()
  def from_transport(reason) do
    %__MODULE__{
      kind: :transport,
      message: transport_message(reason),
      reason: transport_reason(reason)
    }
  end

  # Finch only returns `Finch.error/0` values or the tagged values this module
  # produces, but a transport that grows a new error shape must not crash a call.
  @dialyzer {:nowarn_function, transport_message: 1}
  defp transport_message({:unknown_pool, name}), do: "unknown pool: #{inspect(name)}"
  defp transport_message({:exception, message}), do: "transport error: #{message}"
  defp transport_message(reason) when is_binary(reason), do: "transport error: #{reason}"
  defp transport_message(%_{} = error), do: "transport error: #{Exception.message(error)}"
  defp transport_message(reason), do: "transport error: #{inspect(reason)}"

  @dialyzer {:nowarn_function, transport_reason: 1}
  defp transport_reason({:unknown_pool, _name} = reason), do: reason
  defp transport_reason({:exception, _message}), do: :exception
  defp transport_reason(%Finch.TransportError{reason: reason}), do: reason
  defp transport_reason(%Finch.HTTPError{reason: reason}), do: reason
  defp transport_reason(%Finch.Error{reason: reason}), do: reason
  defp transport_reason(%Mint.TransportError{reason: reason}), do: reason
  defp transport_reason(reason) when is_binary(reason), do: nil
  defp transport_reason(reason), do: reason
end
