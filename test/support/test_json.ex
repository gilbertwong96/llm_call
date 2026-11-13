defmodule LlmCall.TestJSON do
  @moduledoc """
  JSON decoder stub for tests: maps decode to `{:ok, map}` and malformed input to `{:error, reason}`.
  """

  def decode(input) do
    case :json.decode(input) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, "not an object"}
    end
  rescue
    _ -> {:error, "invalid json"}
  end
end
