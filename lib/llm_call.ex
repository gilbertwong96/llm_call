defmodule LlmCall do
  @moduledoc """
  Wire-protocol codec for LLM APIs.

  `LlmCall` turns a provider-neutral request into the request body, path, and
  protocol headers a provider expects, and turns provider response terms into a
  provider-neutral response.

  It owns no transport, authentication, model discovery, tool execution,
  approvals, retries, or agent loop. A codec returns JSON-compatible Elixir
  terms; the caller's HTTP stack performs the request and the JSON encoding.

      {:ok, encoded} = LlmCall.encode(LlmCall.Protocol.Anthropic.Messages, request)
      # transport: POST base_url <> encoded.path with encoded.body
      {:ok, response} = LlmCall.decode_response(LlmCall.Protocol.Anthropic.Messages, payload)

  See `docs/design.md` for the canonical IR contract and the list of protocol
  adapters.
  """

  @type model :: String.t()

  @type capture_raw :: :none | :response | :all

  @type wire_value ::
          nil
          | boolean()
          | number()
          | String.t()
          | [wire_value()]
          | %{optional(String.t()) => wire_value()}

  @type stop_reason ::
          :end_turn
          | :tool_calls
          | :max_tokens
          | :stop_sequence
          | :content_filter
          | :error
          | :unknown
end
