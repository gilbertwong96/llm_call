defmodule LlmCall.Error do
  @moduledoc """
  A codec error.

  `retryable?` is a hint derived from the provider's error code, not a retry
  policy. HTTP transport failures are transport errors and never reach this
  struct.
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
