defmodule LlmCall.Error do
  @moduledoc """
  A codec error.

  `retryable?` is a hint derived from the provider's error code, not a retry
  policy. HTTP transport failures are transport errors and never reach this
  struct.

  `code` is the provider's machine-readable code as a string (OpenAI's `code`,
  Anthropic's error type, Google's status such as `"RESOURCE_EXHAUSTED"`,
  MiniMax's numeric code stringified). `status` is the HTTP status, and **only the
  transport sets it**: a codec never sees the response status, so it always
  leaves it `nil`.
  """

  @type t :: %__MODULE__{
          kind: :protocol | :validation | :invalid_response | :provider,
          message: String.t(),
          code: String.t() | nil,
          status: non_neg_integer() | nil,
          retryable?: boolean(),
          raw: map() | nil
        }

  defstruct kind: nil, message: nil, code: nil, status: nil, retryable?: false, raw: nil
end
