defmodule LlmCall.ToolsTest.NeutralCodec do
  def info, do: %LlmCall.Codec.Info{name: :neutral, protocol: :made_up, ir_version: 1}
end

defmodule LlmCall.ToolsTest do
  use ExUnit.Case, async: true

  alias LlmCall.Dialect.Anthropic.Messages
  alias LlmCall.Error
  alias LlmCall.ToolFixtures.Weather
  alias LlmCall.Tools
  alias LlmCall.ToolSpec
  alias LlmCall.ToolsTest.NeutralCodec

  test "passes ToolSpec entries through untouched" do
    spec = %ToolSpec{name: "hand", description: "d", parameters: %{"type" => "object"}}
    assert {:ok, [^spec]} = Tools.expand([spec], Messages)
  end

  test "expands a module into one spec per declared tool" do
    assert {:ok, specs} = Tools.expand([Weather], Messages)
    assert Enum.map(specs, & &1.name) == ["forecast", "conditions"]
    assert Enum.all?(specs, &is_binary(&1.description))
    assert Enum.all?(specs, &is_map(&1.parameters))
  end

  test "accepts the mixed forms in one list" do
    spec = %ToolSpec{name: "hand", parameters: %{"type" => "object"}}
    assert {:ok, specs} = Tools.expand([spec, Weather], Messages)
    assert Enum.map(specs, & &1.name) == ["hand", "forecast", "conditions"]
  end

  test "rejects a non-list" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Tools.expand(Weather, NeutralCodec)

    assert message == "neutral: tools must be a list"
  end
end
