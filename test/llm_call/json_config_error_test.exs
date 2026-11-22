defmodule LlmCall.JSONConfigErrorTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Content, Error, Message, Request}
  alias LlmCall.TestHTTPServer, as: TestHTTP

  setup do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    :ok
  end

  defp request do
    %Request{model: "m", messages: [%Message{role: :user, content: [%Content.Text{text: "x"}]}]}
  end

  defp client(opts \\ []) do
    LlmCall.TestProvider.client(Keyword.merge([api_key: "k", base_url: TestHTTP.url()], opts))
  end

  test "an encode-side JSON module mistake names the module" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.complete(client(json_library: String), request())

    assert message =~ "String"
    assert message =~ "json_library"
    assert TestHTTP.requests() == []
  end

  test "a decode-side JSON module mistake names the module" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    encoded = %LlmCall.EncodedRequest{method: :get, path: "/asset"}

    assert {:error, %Error{kind: :invalid_response, message: message}} =
             LlmCall.execute(client(json_library: String), encoded)

    assert message =~ "String"
    assert message =~ "json_library"
  end

  test "a body that is genuinely not encodable names the encoder's reason" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}"}})

    encoded = %LlmCall.EncodedRequest{method: :post, path: "/x", body: %{"bad" => {1, 2}}}

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.execute(client(), encoded)

    assert message =~ "request body is not JSON-encodable"
    assert message =~ "("
  end

  test "a response body that is not JSON quotes the body" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "<html>"}})

    encoded = %LlmCall.EncodedRequest{method: :get, path: "/asset"}

    assert {:error, %Error{kind: :invalid_response, message: message}} =
             LlmCall.execute(client(), encoded)

    assert message =~ "response body is not JSON"
    assert message =~ "<html>"
  end
end
