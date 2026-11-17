defmodule LlmDialect.Protocol.AdapterTest do
  use ExUnit.Case, async: true

  test "a codec that supplies its own encode_request/2 must pass encode: false" do
    assert_raise ArgumentError, ~r/encode: false/, fn ->
      Code.compile_string("""
      defmodule LlmDialect.TestCodec.DuplicateEncode do
        @moduledoc false
        @path "/dup"
        @headers []
        use LlmDialect.Protocol.Adapter, codec: :duplicate_encode

        def encode_request(_request, _config), do: :ok
      end
      """)
    end
  end

  test "@path and @headers may be declared after use" do
    [{module, _binary}] =
      Code.compile_string("""
      defmodule LlmDialect.TestCodec.LateAttributes do
        @moduledoc false
        use LlmDialect.Protocol.Adapter, codec: :late_attributes

        @path "/late"
        @headers [{"content-type", "application/json"}]

        @impl true
        def info, do: %LlmDialect.Codec.Info{name: :late, protocol: :late, ir_version: 1}

        @impl true
        def capabilities(_request, _config), do: %LlmDialect.Capabilities{}

        @impl true
        def validate_request(_request, _config), do: :ok

        @impl true
        def decode_response(_term, _config),
          do: {:error, %LlmDialect.Error{kind: :invalid_response, message: "late"}}

        @impl true
        def decode_error(_term, _config),
          do: %LlmDialect.Error{kind: :provider, message: "late"}

        defp body(_request, _config), do: %{"ok" => true}
      end
      """)

    request = %LlmDialect.Request{
      model: "late-1",
      messages: [
        %LlmDialect.Message{role: :user, content: [%LlmDialect.Content.Text{text: "hi"}]}
      ]
    }

    assert {:ok, %LlmDialect.EncodedRequest{path: "/late"}} =
             module.encode_request(request, %LlmDialect.Config{})
  end
end
