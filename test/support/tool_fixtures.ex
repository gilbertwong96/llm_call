defmodule LlmCall.ToolFixtures.Weather do
  @moduledoc """
  A `ToolCall` module with three documented tools, so `ToolCall.describe/2` has
  a description and a schema to carry. `detailed/2` has an optional parameter,
  which is the difference OpenAI's strict mode changes.
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

  @doc """
  Detailed forecast for a city.

  ## Parameters
    * `city` - city name
    * `units` - unit system
  """
  @spec detailed(city :: String.t(), units :: String.t()) ::
          {:ok, %{city: String.t(), units: String.t()}}
  def detailed(city, units \\ "metric"), do: {:ok, %{city: city, units: units}}
end
