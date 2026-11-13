defmodule LlmCall.Media.Codec do
  @moduledoc """
  The behaviour every media generation adapter implements.

  A synchronous codec implements everything except `decode_operation/2`. An
  asynchronous codec also implements `decode_operation/2` and declares
  `async: true` in its capabilities.

  `encode_submit/2` validates first, like the completion side. `decode_submit/2`
  returns either finished assets or an `LlmCall.Operation` whose `next` request
  advances the job.
  """

  @callback info() :: LlmCall.Codec.Info.t()

  @callback capabilities(LlmCall.Media.Request.t(), LlmCall.Config.t()) ::
              LlmCall.Media.Capabilities.t()

  @callback validate_request(LlmCall.Media.Request.t(), LlmCall.Config.t()) ::
              :ok | {:error, LlmCall.Error.t()}

  @callback encode_submit(LlmCall.Media.Request.t(), LlmCall.Config.t()) ::
              {:ok, LlmCall.EncodedRequest.t()} | {:error, LlmCall.Error.t()}

  @callback decode_submit(LlmCall.wire_value(), LlmCall.Config.t()) ::
              {:ok, LlmCall.Media.Response.t()} | {:error, LlmCall.Error.t()}

  @callback decode_operation(LlmCall.wire_value(), LlmCall.Config.t()) ::
              {:ok, LlmCall.Operation.t()} | {:error, LlmCall.Error.t()}

  @callback decode_error(LlmCall.wire_value(), LlmCall.Config.t()) :: LlmCall.Error.t()

  @optional_callbacks decode_operation: 2
end
