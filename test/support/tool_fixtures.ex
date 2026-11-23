defmodule LlmCall.ToolFixtures.Weather do
  @moduledoc """
  A `ToolCall` module with two documented tools, so `ToolCall.describe/2` has a
  description and a schema to carry.
  """

  use ToolCall

  @doc """
  Forecast for a city.

  ## Parameters
    * `city` - city name
  """
  @spec forecast(city :: String.t()) :: {:ok, %{city: String.t()}}
  def forecast(city), do: {:ok, %{city: city}}

  @doc """
  Current conditions.

  ## Parameters
    * `city` - city name
  """
  @spec conditions(city :: String.t()) :: {:ok, %{city: String.t()}}
  def conditions(city), do: {:ok, %{city: city}}
end
