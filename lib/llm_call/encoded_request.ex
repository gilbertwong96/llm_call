defmodule LlmCall.EncodedRequest do
  @moduledoc """
  A request rendered into one protocol's wire shape.

  `body` is a JSON-compatible term, not an encoded JSON string. Headers carry
  protocol facts only; the transport adds credentials and the base URL.
  """

  @type t :: %__MODULE__{
          method: :post | :get,
          path: String.t(),
          query: %{optional(String.t()) => String.t() | integer() | boolean()},
          headers: [{String.t(), String.t()}],
          body: map()
        }

  defstruct method: :post, path: nil, query: %{}, headers: [], body: %{}
end
