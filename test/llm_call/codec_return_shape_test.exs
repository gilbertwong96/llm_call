defmodule LlmCall.CodecReturnShapeTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Content, EncodedRequest, Error, Message, Request}
  alias LlmCall.TestHTTPServer, as: TestHTTP

  defmodule BadDecodeCodec do
    @moduledoc false

    def validate_request(_request, _config), do: :ok

    def encode_request(_request, _config),
      do: {:ok, %EncodedRequest{method: :post, path: "/x", body: %{}}}

    def decode_response(_term, _config), do: :not_a_tuple
    def decode_error(_term, _config), do: %Error{kind: :provider, message: "x"}
    def capabilities(_request, _config), do: %LlmCall.Capabilities{}
  end

  defmodule BadEncodeCodec do
    @moduledoc false

    def validate_request(_request, _config), do: :ok
    def encode_request(_request, _config), do: :not_a_tuple

    def decode_response(_term, _config),
      do: {:error, %Error{kind: :invalid_response, message: "x"}}

    def decode_error(_term, _config), do: %Error{kind: :provider, message: "x"}
    def capabilities(_request, _config), do: %LlmCall.Capabilities{}
  end

  defmodule BadSubmitCodec do
    @moduledoc false

    def validate_request(_request, _config), do: :ok
    def encode_submit(_request, _config), do: :not_a_tuple
    def decode_submit(_term, _config), do: :not_a_tuple
    def decode_operation(_term, _config), do: :not_a_tuple
    def decode_error(_term, _config), do: %Error{kind: :provider, message: "x"}
  end

  defmodule BadDecodeProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :none,
      codecs: [chat: BadDecodeCodec]
  end

  defmodule BadEncodeProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :none,
      codecs: [chat: BadEncodeCodec]
  end

  defmodule BadSubmitProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :none,
      codecs: [images: BadSubmitCodec]
  end

  setup do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}"}})
    :ok
  end

  defp request do
    %Request{model: "m", messages: [%Message{role: :user, content: [%Content.Text{text: "x"}]}]}
  end

  defp media_request do
    %LlmCall.Media.Request{modality: :image, model: "m", prompt: "p"}
  end

  test "complete/3 rejects a decode_response return outside the contract" do
    client = BadDecodeProvider.client(base_url: TestHTTP.url())

    assert {:error, %Error{kind: :invalid_response, message: message}} =
             LlmCall.complete(client, request())

    assert message =~ "decode_response"
  end

  test "complete/3 rejects an encode_request return outside the contract" do
    client = BadEncodeProvider.client(base_url: TestHTTP.url())

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.complete(client, request())

    assert message =~ "encode_request"
    assert TestHTTP.requests() == []
  end

  test "generate/3 rejects an encode_submit return outside the contract" do
    client = BadSubmitProvider.client(base_url: TestHTTP.url())

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.generate(client, media_request(), codec: :images)

    assert message =~ "encode_submit"
    assert TestHTTP.requests() == []
  end

  test "poll/3 rejects a decode_operation return outside the contract" do
    client = BadSubmitProvider.client(base_url: TestHTTP.url())
    encoded = %EncodedRequest{method: :get, path: "/poll"}

    assert {:error, %Error{kind: :invalid_response, message: message}} =
             LlmCall.poll(client, encoded, codec: :images)

    assert message =~ "decode_operation"
  end
end
