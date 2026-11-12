defmodule LlmCall.Usage do
  @moduledoc """
  Token accounting as reported by the provider.

  Pricing and cost are outside the core: they depend on provider, model, region,
  cache, and tier, none of which is a wire field.
  """

  @type tokens :: non_neg_integer() | nil

  @type t :: %__MODULE__{
          input_tokens: tokens(),
          output_tokens: tokens(),
          total_tokens: tokens(),
          cache_read_tokens: tokens(),
          cache_write_tokens: tokens(),
          reasoning_tokens: tokens()
        }

  defstruct input_tokens: nil,
            output_tokens: nil,
            total_tokens: nil,
            cache_read_tokens: nil,
            cache_write_tokens: nil,
            reasoning_tokens: nil
end
