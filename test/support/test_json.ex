defmodule LlmCall.TestJSON do
  @moduledoc false

  def decode(input) do
    case :json.decode(input) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, "not an object"}
    end
  rescue
    _ -> {:error, "invalid json"}
  end
end
