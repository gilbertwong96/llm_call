defmodule LlmCall.QueryParamTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Client, Config, Content, EncodedRequest, Error, Message, Request}
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

  describe "the Responses WebSocket handshake" do
    alias LlmCall.Dialect.OpenAI.Responses.Connection

    defmodule RecordingWS do
      @moduledoc false
      @behaviour LlmCall.WS

      @impl true
      def connect(url, _headers, opts) do
        send(opts[:test_pid], {:ws_url, url})
        {:ok, :conn}
      end

      @impl true
      def send_frame(:conn, _frame), do: {:ok, :conn}
      @impl true
      def feed(:conn, _message), do: {:ok, [], :conn}
      @impl true
      def recv(_conn, _timeout), do: {:error, :timeout}
      @impl true
      def close(_conn, _code, _reason), do: :ok
    end

    defp ws_client(opts) do
      struct(
        %Client{
          provider: LlmCall.TestProvider,
          codecs: %{chat: LlmCall.Dialect.OpenAI.Responses},
          base_url: "https://api.example.test",
          headers: [],
          http_opts: [],
          timeout: 5_000,
          config: %Config{}
        },
        opts
      )
    end

    defp handshake_url(client) do
      {:ok, connection} =
        Connection.start_link(
          client: client,
          ws: RecordingWS,
          ws_opts: [test_pid: self()],
          max_age_ms: 60_000
        )

      assert_receive {:ws_url, url}
      Connection.close(connection)
      url
    end

    test "carries the client query" do
      url = handshake_url(ws_client(query: %{"api-version" => "2024-02-01"}))

      assert url =~ "wss://api.example.test/v1/responses?"
      assert url =~ "api-version=2024-02-01"
    end

    test "merges a query that is already in the base URL" do
      url =
        handshake_url(
          ws_client(
            base_url: "https://api.example.test?foo=1",
            query: %{"api-version" => "2024-02-01"}
          )
        )

      assert url =~ "foo=1"
      assert url =~ "api-version=2024-02-01"
    end

    test "has no query when neither source sets one" do
      assert handshake_url(ws_client([])) == "wss://api.example.test/v1/responses"
    end
  end
end
