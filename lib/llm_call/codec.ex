defmodule LlmCall.Codec do
  @moduledoc """
  The behaviour every dialect adapter implements.

  A codec turns a canonical request into one protocol's wire request, and one
  provider's response terms into canonical responses and stream events. It does
  no IO: transports parse framing and move bytes, while a codec maps terms and uses
  `Config.json` only for wire fields that are themselves JSON strings (tool-call
  arguments).

  Streaming callbacks are optional so a non-streaming codec need not implement
  dummy functions; `LlmCall` returns a typed error when a caller asks a codec
  for streaming it does not implement.

  Streaming state is passed as `LlmCall.StreamState`, which the codec reads with
  `LlmCall.StreamState.data/1` and rebuilds with `LlmCall.StreamState.new/2`.
  """

  @callback info() :: LlmCall.Codec.Info.t()

  @callback encode_request(
              LlmCall.Request.t(),
              LlmCall.Config.t()
            ) ::
              {:ok, LlmCall.EncodedRequest.t()}
              | {:error, LlmCall.Error.t()}

  @callback decode_response(
              LlmCall.wire_value(),
              LlmCall.Config.t()
            ) ::
              {:ok, LlmCall.Response.t()}
              | {:error, LlmCall.Error.t()}

  @callback decode_stream_event(
              LlmCall.wire_value(),
              LlmCall.Config.t(),
              LlmCall.StreamState.t()
            ) ::
              {:ok, [LlmCall.StreamEvent.t()], LlmCall.StreamState.t()}
              | {:done, LlmCall.StreamState.t()}
              | {:error, LlmCall.Error.t()}

  @callback decode_error(
              LlmCall.wire_value(),
              LlmCall.Config.t()
            ) :: LlmCall.Error.t()

  @callback validate_request(
              LlmCall.Request.t(),
              LlmCall.Config.t()
            ) :: :ok | {:error, LlmCall.Error.t()}

  @callback init_stream(
              LlmCall.Request.t(),
              LlmCall.Config.t()
            ) :: {:ok, LlmCall.StreamState.t()} | {:error, LlmCall.Error.t()}

  @callback finish_stream(
              LlmCall.StreamState.t(),
              LlmCall.Config.t()
            ) ::
              {:ok, [LlmCall.StreamEvent.t()], LlmCall.StreamState.t()}
              | {:error, LlmCall.Error.t()}

  @callback capabilities(
              LlmCall.Request.t(),
              LlmCall.Config.t()
            ) :: LlmCall.Capabilities.t()

  @optional_callbacks init_stream: 2, decode_stream_event: 3, finish_stream: 2
end
