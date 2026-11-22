defmodule LlmCall.Excerpt do
  @moduledoc """
  A short, quoted slice of a payload for an error message.

  A provider that answers with HTML, plain text, or a truncated body gives the
  library nothing it can decode, and neither `Error.raw` (a map or `nil`) nor
  `Error.reason` can carry it. The excerpt keeps that failure diagnosable without
  widening either public type.

  The text is trimmed and truncated so a large body does not become an error
  message of the same size.
  """

  @limit 200

  @doc """
  Returns `": <excerpt>"`, or `""` when there is nothing worth quoting.

  The leading colon is part of the value so a caller can append it to a message
  without branching.
  """
  @spec of(term()) :: String.t()
  def of(term) when is_binary(term) and term != "" do
    trimmed = String.trim(term)

    cond do
      trimmed == "" -> ""
      String.length(trimmed) > @limit -> ": " <> String.slice(trimmed, 0, @limit) <> "..."
      true -> ": " <> trimmed
    end
  end

  def of(_term), do: ""
end
