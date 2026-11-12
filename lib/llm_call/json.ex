defmodule LlmCall.JSON do
  @moduledoc false

  # Wire formats that carry tool arguments as a JSON string (OpenAI Chat tool
  # calls, Gemini stream function calls) need an encoder here. This is the OTP
  # standard library, not a package dependency.

  @spec encode(term()) :: String.t()
  def encode(term), do: term |> :json.encode() |> IO.iodata_to_binary()
end
