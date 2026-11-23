defmodule LlmCall.Dialect.HelpersTest do
  use ExUnit.Case, async: true

  alias LlmCall.Dialect.Helpers

  test "capture_response/2 keeps a map and ignores any other term" do
    config = %LlmCall.Config{capture_raw: :all}

    assert Helpers.capture_response(config, %{"a" => 1}) == %{"a" => 1}
    assert Helpers.capture_response(config, [1, 2]) == nil
    assert Helpers.capture_response(%LlmCall.Config{}, %{"a" => 1}) == nil
  end

  test "retryable?/2 is the single rule for the retry hint" do
    assert Helpers.retryable?("rate_limit_exceeded", ["rate_limit_exceeded"])
    refute Helpers.retryable?(nil, ["rate_limit_exceeded"])
    refute Helpers.retryable?("other", ["rate_limit_exceeded"])
    refute Helpers.retryable?(429, ["429"])
    refute Helpers.retryable?(%{"code" => 429}, ["429"])
  end

  test "code/1 normalizes provider codes so Error.code is always a string" do
    assert Helpers.code("RESOURCE_EXHAUSTED") == "RESOURCE_EXHAUSTED"
    assert Helpers.code(429) == "429"
    assert Helpers.code(nil) == nil
    assert Helpers.code(%{"weird" => true}) == nil
  end

  test "validate_unique_tool_names/2 rejects a repeated function name" do
    tools = fn names -> Enum.map(names, &%LlmCall.ToolSpec{name: &1}) end

    assert :ok == Helpers.validate_unique_tool_names(tools.(["a", "b"]), :codec)

    assert {:error, %{kind: :validation, message: message}} =
             Helpers.validate_unique_tool_names(tools.(["a", "a"]), :codec)

    assert message =~ ~s(tool name "a" is declared more than once)

    # A builtin tool and a function tool may not share a name either.
    assert {:error, %{message: message}} =
             Helpers.validate_unique_tool_names(
               [
                 %LlmCall.ToolSpec{name: "search"},
                 %LlmCall.ToolSpec{kind: :builtin, name: "search"}
               ],
               :codec
             )

    assert message =~ "more than once"
  end

  test "validate_tool_name/3 enforces the protocol class it is given" do
    openai = {~r/\A[a-zA-Z0-9_-]+\z/, 64, "OpenAI Chat"}

    assert :ok == Helpers.validate_tool_name("get_weather", :codec, openai)
    assert :ok == Helpers.validate_tool_name("get-weather", :codec, openai)

    assert {:error, %{kind: :validation, message: message}} =
             Helpers.validate_tool_name("weather.get", :codec, openai)

    assert message =~ "must match"

    assert {:error, %{message: message}} =
             Helpers.validate_tool_name(String.duplicate("a", 65), :codec, openai)

    assert message =~ "exceeds"

    # `:any` means the protocol publishes no constraint.
    assert :ok == Helpers.validate_tool_name("weather.get", :codec, :any)
    assert :ok == Helpers.validate_tool_name(String.duplicate("a", 200), :codec, :any)
  end

  test "decode_provider_error/5 keeps a non-map payload diagnosable" do
    html = "<html>502 Bad Gateway</html>"

    error = Helpers.decode_provider_error(html, %LlmCall.Config{}, :codec, ["code"], [])

    assert error.kind == :invalid_response
    assert error.message =~ "unrecognized error payload"
    assert error.message =~ html
    assert is_nil(error.raw)

    # A JSON payload still goes to `raw`, and nothing is appended to the message.
    map_error =
      Helpers.decode_provider_error(%{"a" => 1}, %LlmCall.Config{}, :codec, ["code"], [])

    assert is_nil(map_error.raw)
    assert map_error.message == "codec: unrecognized error payload"

    captured =
      Helpers.decode_provider_error(
        %{"a" => 1},
        %LlmCall.Config{capture_raw: :all},
        :codec,
        ["code"],
        []
      )

    assert captured.raw == %{"a" => 1}
  end

  test "decode_provider_error/5 truncates a long payload excerpt" do
    error =
      Helpers.decode_provider_error(String.duplicate("x", 500), %LlmCall.Config{}, :codec, [], [])

    assert error.message =~ "..."
    assert String.length(error.message) < 300
  end

  test "param validation has one entry point that checks values" do
    # A key-only validator used to exist next to the spec-driven one, under a
    # shorter name that made it the obvious choice for an out-of-tree adapter —
    # while it accepted `temperature: "hot"`. Only the spec-driven form remains.
    functions =
      LlmCall.Dialect.Helpers.__info__(:functions)
      |> Enum.filter(fn {name, _arity} ->
        String.starts_with?(Atom.to_string(name), "validate_param")
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert functions ==
             [:validate_param_keys, :validate_param_values, :validate_params_with_spec]

    # The remaining key-only primitive still exists for a codec that validates its
    # values itself, but it is not presented as the params entry point.
    assert {:error, %{kind: :validation}} =
             Helpers.validate_params_with_spec(
               %{temperature: "hot"},
               [:temperature],
               %{
                 temperature: {:number, 0, 2}
               },
               :codec
             )
  end

  describe "validate_param_values/4" do
    @spec_map %{
      temperature: {:number, 0, 2},
      max_tokens: {:integer, 1, :infinity},
      seed: :integer,
      stop: {:stop, 4}
    }
    @keys [:temperature, :max_tokens, :seed, :stop]

    defp validate_params(params, codec \\ :test_codec) do
      Helpers.validate_param_values(params, @keys, @spec_map, codec)
    end

    test "accepts values inside the declared range" do
      assert :ok == validate_params(%{temperature: 0})
      assert :ok == validate_params(%{temperature: 2})
      assert :ok == validate_params(%{temperature: 0.7})
      assert :ok == validate_params(%{max_tokens: 1})
      assert :ok == validate_params(%{seed: -1})
      assert :ok == validate_params(%{stop: "END"})
      assert :ok == validate_params(%{stop: ["a", "b"]})
    end

    test "ignores a nil value, which means provider default" do
      assert :ok == validate_params(%{temperature: nil, max_tokens: nil})
      assert :ok == validate_params(%{})
    end

    test "rejects a value outside its range or of the wrong type" do
      assert {:error, %{kind: :validation, message: message}} =
               validate_params(%{temperature: 2.1})

      assert message =~ "between 0 and 2"

      assert {:error, %{message: message}} = validate_params(%{temperature: "hot"})
      assert message =~ "must be a number"

      assert {:error, %{message: message}} = validate_params(%{max_tokens: 0})
      assert message =~ "at least 1"

      assert {:error, %{message: message}} = validate_params(%{seed: "x"})
      assert message =~ "must be an integer"
    end

    test "rejects a stop that is empty, blank, over the limit, or not a string list" do
      for stop <- ["", [], [""], ["a", "b", "c", "d", "e"], 123] do
        assert {:error, %{kind: :validation, message: message}} = validate_params(%{stop: stop})
        assert message =~ "stop"
      end
    end

    test "an unknown key is still rejected before its value is considered" do
      assert {:error, %{message: message}} = validate_params(%{unknown: 1})
      assert message =~ "not supported"
    end
  end

  describe "validate_tool_call_arguments/3" do
    @codec2 :test_codec

    test "a fragment with a decoder verdict is replayable, whatever it holds" do
      for error <- [{:invalid_json, "not valid JSON"}, :no_json_decoder],
          raw <- [~s({"city":), "[1,2]", "not json at all"] do
        call = %LlmCall.ToolCall{id: "c", name: "f", raw_arguments: raw, arguments_error: error}
        assert :ok == Helpers.validate_tool_call_arguments(call, @codec2, JSON)
      end
    end

    test "a fragment without a verdict must decode to an object" do
      assert :ok ==
               Helpers.validate_tool_call_arguments(
                 %LlmCall.ToolCall{id: "c", name: "f", raw_arguments: ~s({"a":1})},
                 @codec2,
                 JSON
               )

      for raw <- [~s({"a":), "[1,2]", "null"] do
        assert {:error, %{message: message}} =
                 Helpers.validate_tool_call_arguments(
                   %LlmCall.ToolCall{id: "c", name: "f", raw_arguments: raw},
                   @codec2,
                   JSON
                 )

        assert message =~ "must decode to an object"
      end
    end

    test "a map is validated by encodability and nil is accepted" do
      assert :ok ==
               Helpers.validate_tool_call_arguments(
                 %LlmCall.ToolCall{id: "c", name: "f", arguments: %{"a" => 1}},
                 @codec2,
                 JSON
               )

      assert :ok ==
               Helpers.validate_tool_call_arguments(
                 %LlmCall.ToolCall{id: "c", name: "f"},
                 @codec2,
                 JSON
               )

      assert {:error, %{message: message}} =
               Helpers.validate_tool_call_arguments(
                 %LlmCall.ToolCall{id: "c", name: "f", raw_arguments: 123},
                 @codec2,
                 JSON
               )

      assert message =~ "must be a string"
    end
  end

  describe "tool_choice cross-references the declared tools" do
    @tools [
      %LlmCall.ToolSpec{name: "get_weather"},
      %LlmCall.ToolSpec{kind: :builtin, name: "web_search_20250305"}
    ]
    @codec :test_codec

    test "a chosen tool must be declared" do
      assert :ok == Helpers.validate_tool_choice({:tool, "get_weather"}, @tools, @codec)

      # A builtin tool is declared by name too, so it is choosable.
      assert :ok == Helpers.validate_tool_choice({:tool, "web_search_20250305"}, @tools, @codec)

      assert {:error, %{kind: :validation, message: message}} =
               Helpers.validate_tool_choice({:tool, "nonexistent"}, @tools, @codec)

      assert message =~ ~s(tool_choice names "nonexistent")
      assert message =~ "no tool in the request declares"
    end

    test "an allowed list must be non-empty and only name declared tools" do
      assert :ok == Helpers.validate_allowed_tools(["get_weather"], @tools, @codec)

      assert :ok ==
               Helpers.validate_allowed_tools(
                 ["get_weather", "web_search_20250305"],
                 @tools,
                 @codec
               )

      assert {:error, %{message: message}} = Helpers.validate_allowed_tools([], @tools, @codec)
      assert message =~ "requires at least one name"

      assert {:error, %{message: message}} =
               Helpers.validate_allowed_tools(["get_weather", "nope"], @tools, @codec)

      assert message =~ ~s(\"nope\")

      for bad <- [[""], [nil], [123]] do
        assert {:error, %{message: message}} = Helpers.validate_allowed_tools(bad, @tools, @codec)
        assert message =~ "non-empty strings"
      end
    end

    test "the choice is still rejected when no tool is declared at all" do
      assert {:error, %{message: message}} =
               Helpers.validate_tool_choice({:tool, "get_weather"}, [], @codec)

      assert message =~ "requires at least one tool"
    end
  end
end
