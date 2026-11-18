defmodule LlmCall.ClientTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Client, Config, Error, HTTP, MarkerJSON, Request, Response}
  alias LlmCall.HTTP.Test, as: FakeHTTP
  alias LlmCall.TestProvider

  setup do
    FakeHTTP.reset()
    :ok
  end

  defp client(opts \\ []) do
    TestProvider.client(Keyword.merge([api_key: "secret", http: FakeHTTP], opts))
  end

  defp request(overrides \\ []) do
    struct(
      %Request{
        model: "fake-1",
        messages: [%LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "hi"}]}]
      },
      overrides
    )
  end

  test "complete/3 resolves the provider, encodes the body and decodes the response" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    assert {:ok, %Response{content: [%LlmCall.Content.Text{text: "pong"}]}} =
             LlmCall.complete(client(), request())

    assert [sent] = FakeHTTP.requests()
    assert sent.url == "https://api.example.test/v1/fake"
    assert {"authorization", "Bearer secret"} in sent.headers
    assert {:ok, %{"model" => "fake-1"}} = LlmCall.JSON.decode(sent.body)
    assert sent.receive_timeout == 60_000
  end

  test "a non-2xx envelope is decoded by the codec and carries the status" do
    FakeHTTP.put_response(
      {:ok, %{status: 401, headers: [], body: ~s({"error":{"message":"bad key"}})}}
    )

    assert {:error, %Error{kind: :provider, message: "bad key", status: 401}} =
             LlmCall.complete(client(), request())
  end

  test "an undecodable 2xx body is :invalid_response" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: "not json"}})

    assert {:error, %Error{kind: :invalid_response}} = LlmCall.complete(client(), request())
  end

  test "an undecodable error body is :transport with the status" do
    FakeHTTP.put_response({:ok, %{status: 502, headers: [], body: "<html>"}})

    assert {:error, %Error{kind: :transport, status: 502}} = LlmCall.complete(client(), request())
  end

  test "a transport failure is :transport" do
    FakeHTTP.put_response({:error, :econnrefused})

    assert {:error, %Error{kind: :transport, message: message}} =
             LlmCall.complete(client(), request())

    assert message =~ "econnrefused"
  end

  test "stream: true is rejected in favour of stream/3" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.complete(client(), request(stream: true))

    assert message =~ "stream/3"
    assert FakeHTTP.requests() == []
  end

  test "an undeclared codec name lists what the provider declares" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.complete(client(), request(), codec: :vision)

    assert message =~ ":vision"
    assert message =~ ":chat"
  end

  test "execute/3 decodes the body; fetch/3 returns bytes" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"a":1})}})

    encoded = %LlmCall.EncodedRequest{method: :get, path: "/asset", query: %{"x" => 1}}

    assert {:ok, %{status: 200, body: %{"a" => 1}}} = LlmCall.execute(client(), encoded)
    assert {:ok, %{status: 200, body: ~s({"a":1})}} = LlmCall.fetch(client(), encoded)

    sent = List.last(FakeHTTP.requests())
    assert sent.url == "https://api.example.test/v1/asset?x=1"
  end

  test "an unencodable body is :validation, before any request" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}"}})

    encoded = %LlmCall.EncodedRequest{method: :post, path: "/x", body: %{"bad" => {1, 2}}}

    assert {:error, %Error{kind: :validation}} = LlmCall.execute(client(), encoded)
    assert FakeHTTP.requests() == []
  end

  test "json: on the client reaches the boundary and the codec" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    client = client(json: MarkerJSON)

    assert %Client{config: %Config{json: MarkerJSON}} = client
    assert {:ok, %Response{}} = LlmCall.complete(client, request())

    assert [sent] = FakeHTTP.requests()
    assert String.starts_with?(sent.body, "MARKER:")
  end

  test "http_opts and timeout are forwarded" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    assert {:ok, _response} =
             LlmCall.complete(client(http_opts: [name: MyPool], timeout: 5_000), request())

    assert [sent] = FakeHTTP.requests()
    assert sent.receive_timeout == 5_000
  end

  test "the application environment supplies the seam defaults" do
    on_exit(fn -> Application.delete_env(:llm_call, :http) end)
    Application.put_env(:llm_call, :http, FakeHTTP)
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    assert {:ok, _response} = LlmCall.complete(TestProvider.client(api_key: "k"), request())
    assert [%{url: "https://api.example.test/v1/fake"}] = FakeHTTP.requests()
  end

  test "auth shapes become headers" do
    defmodule ApiKeyProvider do
      use LlmCall.Provider,
        base_url: "https://x.test",
        auth: :x_api_key,
        codecs: [chat: LlmCall.TestCodec.Fake]
    end

    defmodule HeaderProvider do
      use LlmCall.Provider,
        base_url: "https://x.test",
        auth: {:header, "x-custom"},
        codecs: [chat: LlmCall.TestCodec.Fake]
    end

    assert %Client{headers: [{"x-api-key", "k"}]} = ApiKeyProvider.client(api_key: "k")
    assert %Client{headers: [{"x-custom", "k"}]} = HeaderProvider.client(api_key: "k")
    assert_raise ArgumentError, ~r/api_key is required/, fn -> ApiKeyProvider.client([]) end
  end
end
