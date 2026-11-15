defmodule LlmDialect.Media.Codec do
  @moduledoc """
  The behaviour every media generation adapter implements.

  A synchronous codec implements everything except `decode_operation/2`. An
  asynchronous codec also implements `decode_operation/2` and declares
  `async: true` in its capabilities.

  `encode_submit/2` validates first, like the completion side. `decode_submit/2`
  returns either finished assets or an `LlmDialect.Operation` whose `next` request
  advances the job.
  """

  @callback info() :: LlmDialect.Codec.Info.t()

  @callback capabilities(LlmDialect.Media.Request.t(), LlmDialect.Config.t()) ::
              LlmDialect.Media.Capabilities.t()

  @callback validate_request(LlmDialect.Media.Request.t(), LlmDialect.Config.t()) ::
              :ok | {:error, LlmDialect.Error.t()}

  @callback encode_submit(LlmDialect.Media.Request.t(), LlmDialect.Config.t()) ::
              {:ok, LlmDialect.EncodedRequest.t()} | {:error, LlmDialect.Error.t()}

  @callback decode_submit(LlmDialect.wire_value(), LlmDialect.Config.t()) ::
              {:ok, LlmDialect.Media.Response.t()} | {:error, LlmDialect.Error.t()}

  @callback decode_operation(LlmDialect.wire_value(), LlmDialect.Config.t()) ::
              {:ok, LlmDialect.Operation.t()} | {:error, LlmDialect.Error.t()}

  @callback decode_error(LlmDialect.wire_value(), LlmDialect.Config.t()) :: LlmDialect.Error.t()

  @optional_callbacks decode_operation: 2
end
