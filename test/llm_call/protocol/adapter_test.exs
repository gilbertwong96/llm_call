defmodule LlmCall.Protocol.AdapterTest do
  use ExUnit.Case, async: true

  test "a codec that supplies its own encode_request/2 must pass encode: false" do
    assert_raise ArgumentError, ~r/encode: false/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.DuplicateEncode do
        @moduledoc false
        @path "/dup"
        @headers []
        use LlmCall.Protocol.Adapter, codec: :duplicate_encode

        def encode_request(_request, _config), do: :ok
      end
      """)
    end
  end

  test "@headers must be valid header pairs" do
    assert_raise ArgumentError, ~r/@headers/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.BadHeaders do
        @moduledoc false
        @path "/bad"
        @headers ["bad"]
        use LlmCall.Protocol.Adapter, codec: :bad_headers

        @impl true
        def info, do: %LlmCall.Codec.Info{name: :bad_headers, protocol: :bad_headers, ir_version: 1}

        @impl true
        def capabilities(_request, _config), do: %LlmCall.Capabilities{}

        @impl true
        def validate_request(_request, _config), do: :ok

        @impl true
        def decode_response(_term, _config),
          do: {:error, %LlmCall.Error{kind: :invalid_response, message: "bad"}}

        @impl true
        def decode_error(_term, _config),
          do: %LlmCall.Error{kind: :provider, message: "bad"}

        defp body(_request, _config), do: {:ok, %{}}
      end
      """)
    end
  end

  test "@path and @headers may be declared after use" do
    [{module, _binary}] =
      Code.compile_string("""
      defmodule LlmCall.TestCodec.LateAttributes do
        @moduledoc false
        use LlmCall.Protocol.Adapter, codec: :late_attributes

        @path "/late"
        @headers [{"content-type", "application/json"}]

        @impl true
        def info, do: %LlmCall.Codec.Info{name: :late, protocol: :late, ir_version: 1}

        @impl true
        def capabilities(_request, _config), do: %LlmCall.Capabilities{}

        @impl true
        def validate_request(_request, _config), do: :ok

        @impl true
        def decode_response(_term, _config),
          do: {:error, %LlmCall.Error{kind: :invalid_response, message: "late"}}

        @impl true
        def decode_error(_term, _config),
          do: %LlmCall.Error{kind: :provider, message: "late"}

        defp body(_request, _config), do: {:ok, %{"ok" => true}}
      end
      """)

    request = %LlmCall.Request{
      model: "late-1",
      messages: [
        %LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "hi"}]}
      ]
    }

    assert {:ok, %LlmCall.EncodedRequest{path: "/late"}} =
             module.encode_request(request, %LlmCall.Config{})
  end
end
