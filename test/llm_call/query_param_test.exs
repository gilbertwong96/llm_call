defmodule LlmCall.QueryParamTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Client, Content, EncodedRequest, Error, Message, Request}
  alias LlmCall.TestHTTPServer, as: TestHTTP

  defmodule QueryProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :bearer,
      query: %{"GroupId" => "declared"},
      codecs: [chat: LlmCall.TestCodec.Fake]
  end

  defmodule GeminiProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :none,
      codecs: [chat: LlmCall.Dialect.Gemini.GenerateContent]
  end

  setup do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    :ok
  end

  defp client(opts \\ []) do
    QueryProvider.client(Keyword.merge([api_key: "k", base_url: TestHTTP.url()], opts))
  end

  defp request do
    %Request{model: "m", messages: [%Message{role: :user, content: [%Content.Text{text: "x"}]}]}
  end

  test "a provider-level query reaches every request URL" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    assert {:ok, _response} = LlmCall.complete(client(), request())
    assert [sent] = TestHTTP.requests()
    assert sent.path == "/fake?GroupId=declared"
  end

  test "a client query option overrides the declaration" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    assert %Client{query: %{"GroupId" => "mine"}} = client(query: %{"GroupId" => "mine"})

    assert {:ok, _response} = LlmCall.complete(client(query: [{"GroupId", "mine"}]), request())
    assert [sent] = TestHTTP.requests()
    assert sent.path == "/fake?GroupId=mine"
  end

  test "a codec query parameter wins over the client's" do
    TestHTTP.put_events([{:status, 200}, {:data, "data: {}\n\n"}, {:data, "data: [DONE]\n\n"}])

    gemini = GeminiProvider.client(base_url: TestHTTP.url(), query: %{"alt" => "json"})

    assert {:ok, stream} = LlmCall.stream(gemini, request())
    _ = Enum.to_list(stream)

    assert [sent] = TestHTTP.requests()
    assert sent.path == "/v1beta/models/m:streamGenerateContent?alt=sse"
  end

  test "a malformed query option is rejected at build time" do
    for query <- [:bad, 1, [{"a", :b}], %{"a" => nil}, %{"a" => %{}}] do
      assert_raise ArgumentError, ~r/:query/, fn -> client(query: query) end
    end
  end

  test "execute/2 composes the client query with the encoded one" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}"}})

    encoded = %EncodedRequest{method: :get, path: "/asset", query: %{"task_id" => "t1"}}

    assert {:ok, _response} = LlmCall.execute(client(), encoded)
    assert [sent] = TestHTTP.requests()
    assert sent.path == "/asset?GroupId=declared&task_id=t1"
  end

  test "an invalid encoded query is still a validation error" do
    encoded = %EncodedRequest{method: :get, path: "/asset", query: %{"a" => {1, 2}}}

    assert {:error, %Error{kind: :validation}} = LlmCall.execute(client(), encoded)
  end
end
