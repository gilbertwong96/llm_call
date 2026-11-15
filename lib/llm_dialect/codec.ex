defmodule LlmDialect.Codec do
  @moduledoc """
  The behaviour every protocol adapter implements.

  A codec turns a canonical request into one protocol's wire request, and one
  provider's response terms into canonical responses and stream events. It does
  no IO: transports parse framing and decode JSON, codecs only map terms.

  Streaming callbacks are optional so a non-streaming codec need not implement
  dummy functions; `LlmDialect` returns a typed error when a caller asks a codec
  for streaming it does not implement.

  Streaming state is passed as `LlmDialect.StreamState`, which the codec reads with
  `LlmDialect.StreamState.data/1` and rebuilds with `LlmDialect.StreamState.new/2`.
  """

  @callback info() :: LlmDialect.Codec.Info.t()

  @callback encode_request(
              LlmDialect.Request.t(),
              LlmDialect.Config.t()
            ) ::
              {:ok, LlmDialect.EncodedRequest.t()}
              | {:error, LlmDialect.Error.t()}

  @callback decode_response(
              LlmDialect.wire_value(),
              LlmDialect.Config.t()
            ) ::
              {:ok, LlmDialect.Response.t()}
              | {:error, LlmDialect.Error.t()}

  @callback decode_stream_event(
              LlmDialect.wire_value(),
              LlmDialect.Config.t(),
              LlmDialect.StreamState.t()
            ) ::
              {:ok, [LlmDialect.StreamEvent.t()], LlmDialect.StreamState.t()}
              | {:done, LlmDialect.StreamState.t()}
              | {:error, LlmDialect.Error.t()}

  @callback decode_error(
              LlmDialect.wire_value(),
              LlmDialect.Config.t()
            ) :: LlmDialect.Error.t()

  @callback validate_request(
              LlmDialect.Request.t(),
              LlmDialect.Config.t()
            ) :: :ok | {:error, LlmDialect.Error.t()}

  @callback init_stream(
              LlmDialect.Request.t(),
              LlmDialect.Config.t()
            ) :: {:ok, LlmDialect.StreamState.t()} | {:error, LlmDialect.Error.t()}

  @callback finish_stream(
              LlmDialect.StreamState.t(),
              LlmDialect.Config.t()
            ) ::
              {:ok, [LlmDialect.StreamEvent.t()], LlmDialect.StreamState.t()}
              | {:error, LlmDialect.Error.t()}

  @callback capabilities(
              LlmDialect.Request.t(),
              LlmDialect.Config.t()
            ) :: LlmDialect.Capabilities.t()

  @optional_callbacks init_stream: 2, decode_stream_event: 3, finish_stream: 2
end
