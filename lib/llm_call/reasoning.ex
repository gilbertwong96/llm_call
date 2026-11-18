defmodule LlmCall.Reasoning do
  @moduledoc """
  Canonical reasoning controls.

  Providers expose different axes, so `effort` is a hint, `budget_tokens` is for
  explicit thinking budgets, and `summary` is for a separate reasoning-summary
  control. A codec that cannot express a non-nil field returns a validation
  error instead of dropping it.
  """

  @type level :: :none | :minimal | :low | :medium | :high | :xhigh | :max

  @type effort :: level() | nil

  @type summary :: :none | :auto | :concise | :detailed | nil

  @type t :: %__MODULE__{
          effort: effort(),
          budget_tokens: pos_integer() | nil,
          summary: summary(),
          provider_options: map()
        }

  defstruct effort: nil, budget_tokens: nil, summary: nil, provider_options: %{}
end
