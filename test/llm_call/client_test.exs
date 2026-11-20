defmodule LlmCall.ClientTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Client, Config, Error, MarkerJSON, Request, Response}
  alias LlmCall.TestHTTPServer, as: TestHTTP
  alias LlmCall.TestProvider

  setup do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    :ok
  end

  defp client(opts \\ []) do
    TestProvider.client(Keyword.merge([api_key: "secret", base_url: TestHTTP.url()], opts))
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
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    assert {:ok, %Response{content: [%LlmCall.Content.Text{text: "pong"}]}} =
             LlmCall.complete(client(), request())

    assert [sent] = TestHTTP.requests()
    assert sent.path == "/fake"
    assert {"authorization", "Bearer secret"} in sent.headers
    assert {:ok, %{"model" => "fake-1"}} = LlmCall.JSON.decode(sent.body)
  end

  test "a non-2xx envelope is decoded by the codec and carries the status" do
    TestHTTP.put_response(
      {:ok, %{status: 401, headers: [], body: ~s({"error":{"message":"bad key"}})}}
    )

    assert {:error, %Error{kind: :provider, message: "bad key", status: 401}} =
             LlmCall.complete(client(), request())
  end

  test "an undecodable 2xx body is :invalid_response" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "not json"}})

    assert {:error, %Error{kind: :invalid_response}} = LlmCall.complete(client(), request())
  end

  test "a non-2xx Retry-After becomes retry_after_ms" do
    TestHTTP.put_response(
      {:ok,
       %{
         status: 429,
         headers: [{"retry-after", "2"}],
         body: ~s({"error":{"message":"slow down"}})
       }}
    )

    assert {:error, %Error{kind: :provider, status: 429, retry_after_ms: 2_000}} =
             LlmCall.complete(client(), request())
  end

  test "an invalid Retry-After is left nil" do
    TestHTTP.put_response(
      {:ok,
       %{
         status: 429,
         headers: [{"retry-after", "soon"}],
         body: ~s({"error":{"message":"slow down"}})
       }}
    )

    assert {:error, %Error{retry_after_ms: nil}} = LlmCall.complete(client(), request())
  end

  test "execute/2 reports Retry-After on a non-2xx transport error" do
    TestHTTP.put_response({:ok, %{status: 503, headers: [{"retry-after", "3"}], body: ""}})
    encoded = %LlmCall.EncodedRequest{method: :get, path: "/asset"}

    assert {:error, %Error{kind: :transport, status: 503, retry_after_ms: 3_000}} =
             LlmCall.execute(client(), encoded)
  end

  test "an undecodable error body is :transport with the status" do
    TestHTTP.put_response({:ok, %{status: 502, headers: [], body: "<html>"}})

    assert {:error, %Error{kind: :transport, status: 502}} = LlmCall.complete(client(), request())
  end

  test "a transport failure is :transport" do
    client = TestProvider.client(api_key: "secret", base_url: "http://127.0.0.1:1")

    assert {:error, %Error{kind: :transport, message: message}} =
             LlmCall.complete(client, request())

    assert message == "transport error: connection refused"
  end

  test "stream: true is rejected in favour of stream/3" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.complete(client(), request(stream: true))

    assert message =~ "stream/3"
    assert TestHTTP.requests() == []
  end

  test "an undeclared codec name lists what the provider declares" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.complete(client(), request(), codec: :vision)

    assert message =~ ":vision"
    assert message =~ ":chat"
  end

  test "Client.codec/2 and codec!/2 resolve a named codec" do
    client = client()

    assert Client.codec(client, :chat) == LlmCall.TestCodec.Fake
    assert Client.codec!(client, :chat) == LlmCall.TestCodec.Fake
    assert Client.codec(client, :vision) == nil

    assert_raise ArgumentError, ~r/does not declare a :vision codec/, fn ->
      Client.codec!(client, :vision)
    end
  end

  test "execute/2 decodes the body; fetch/2 returns bytes" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"a":1})}})

    encoded = %LlmCall.EncodedRequest{method: :get, path: "/asset", query: %{"x" => 1}}

    assert {:ok, %{status: 200, body: %{"a" => 1}}} = LlmCall.execute(client(), encoded)
    assert {:ok, %{status: 200, body: ~s({"a":1})}} = LlmCall.fetch(client(), encoded)

    sent = List.last(TestHTTP.requests())
    assert sent.path == "/asset?x=1"
  end

  test "execute/2 and fetch/2 reject a malformed encoded request instead of raising" do
    client = client()

    for encoded <- [
          %LlmCall.EncodedRequest{method: :get, path: nil},
          %LlmCall.EncodedRequest{method: :get, path: "/x", query: %{"a" => {1, 2}}},
          %LlmCall.EncodedRequest{method: :post, path: "/x", headers: ["bad"], body: %{}}
        ] do
      assert {:error, %Error{kind: :validation}} = LlmCall.execute(client, encoded)
      assert {:error, %Error{kind: :validation}} = LlmCall.fetch(client, encoded)
    end

    assert TestHTTP.requests() == []
  end

  test "a base_url with a trailing slash does not produce a double slash" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    client = client(base_url: TestHTTP.url() <> "/")

    assert {:ok, %Response{}} = LlmCall.complete(client, request())
    assert [sent] = TestHTTP.requests()
    assert sent.path == "/fake"
  end

  test "an unencodable body is :validation, before any request" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}"}})

    encoded = %LlmCall.EncodedRequest{method: :post, path: "/x", body: %{"bad" => {1, 2}}}

    assert {:error, %Error{kind: :validation}} = LlmCall.execute(client(), encoded)
    assert TestHTTP.requests() == []
  end

  test "json_library: on the client reaches the boundary and the codec" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    client = client(json_library: MarkerJSON)

    assert %Client{config: %Config{json: MarkerJSON}} = client
    assert {:ok, %Response{}} = LlmCall.complete(client, request())

    assert [sent] = TestHTTP.requests()
    assert String.starts_with?(sent.body, "MARKER:")
  end

  test "http_opts and timeout are part of the client" do
    assert %Client{http_opts: [name: MyPool], timeout: 5_000} =
             client(http_opts: [name: MyPool], timeout: 5_000)
  end

  test "a query in the base URL becomes a request parameter, not part of the path" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    client = client(base_url: TestHTTP.url() <> "/openai?api-version=2024-02-01")

    assert %Client{base_url: base_url, query: %{"api-version" => "2024-02-01"}} = client
    assert base_url == TestHTTP.url() <> "/openai"

    assert {:ok, %Response{}} = LlmCall.complete(client, request())

    assert [sent] = TestHTTP.requests()
    assert sent.path == "/openai/fake?api-version=2024-02-01"
  end

  test "an explicit query option wins over the base URL query" do
    assert %Client{query: %{"api-version" => "call"}} =
             client(
               base_url: TestHTTP.url() <> "/openai?api-version=url",
               query: %{"api-version" => "call"}
             )
  end

  test "request_timeout in http_opts reaches the transport" do
    TestHTTP.put_response(
      {:ok, %{status: 200, headers: [], body: ~s({"text":"late"}), delay: 200}}
    )

    client = client(http_opts: [request_timeout: 1])

    assert {:error, %Error{kind: :transport}} = LlmCall.complete(client, request())
  end

  test "client headers must be string pairs" do
    assert_raise ArgumentError, ~r/:headers must be/, fn ->
      client(headers: ["bad"])
    end
  end

  test "client timeout must be positive or infinity" do
    assert_raise ArgumentError, ~r/:timeout must be/, fn -> client(timeout: -1) end
    assert_raise ArgumentError, ~r/:timeout must be/, fn -> client(timeout: "soon") end
  end

  test "client http_opts must be a keyword list" do
    assert_raise ArgumentError, ~r/:http_opts must be/, fn -> client(http_opts: :not_a_list) end
  end

  test "client http_opts values are type checked" do
    for opts <- [
          [request_timeout: "x"],
          [pool_timeout: nil],
          [name: "not-an-atom"],
          [pool_strategy: :bogus]
        ] do
      assert_raise ArgumentError, ~r/:http_opts/, fn -> client(http_opts: opts) end
    end

    assert %Client{http_opts: [request_timeout: 5_000, pool_timeout: 1_000]} =
             client(http_opts: [request_timeout: 5_000, pool_timeout: 1_000])

    assert %Client{http_opts: [pool_strategy: :random]} =
             client(http_opts: [pool_strategy: :random])
  end

  test "http_opts rejects keys the client would drop" do
    assert_raise ArgumentError, ~r/:http_opts does not accept :receive_timeout/, fn ->
      client(http_opts: [receive_timeout: 5_000])
    end

    assert_raise ArgumentError, ~r/:http_opts does not accept :conn_opts/, fn ->
      client(http_opts: [conn_opts: []])
    end
  end

  test "unknown client options are rejected" do
    assert_raise ArgumentError, ~r/unknown option :json/, fn -> client(json: MarkerJSON) end
  end

  test "the documented example base URL composes the real endpoint" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    client = LlmCall.Examples.OpenAI.client(api_key: "k", base_url: TestHTTP.url())
    {:ok, encoded} = LlmCall.encode(LlmCall.Dialect.OpenAI.Chat, request())

    assert {:ok, _response} = LlmCall.execute(client, encoded)
    assert [sent] = TestHTTP.requests()
    assert sent.path == "/v1/chat/completions"
  end

  test "a provider option must be a literal" do
    assert_raise ArgumentError, ~r/:base_url must be a literal/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.NonLiteralBase do
        @moduledoc false
        use LlmCall.Provider,
          base_url: Application.fetch_env!(:llm_call, :missing),
          auth: :none,
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)
    end
  end

  test "json_library and auth declarations must be literals" do
    assert_raise ArgumentError, ~r/:json_library must be a literal/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.NonLiteralJSON do
        @moduledoc false
        use LlmCall.Provider,
          base_url: "https://x.test",
          auth: :none,
          json_library: System.get_env("LLM_JSON"),
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)
    end

    assert_raise ArgumentError, ~r/:auth must be a literal/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.NonLiteralAuth do
        @moduledoc false
        use LlmCall.Provider,
          base_url: "https://x.test",
          auth: System.get_env("AUTH"),
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)
    end
  end

  test "provider timeout and headers are validated at compile time" do
    assert_raise ArgumentError, ~r/:timeout must be/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.BadTimeout do
        @moduledoc false
        use LlmCall.Provider,
          base_url: "https://x.test",
          auth: :none,
          timeout: -1,
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)
    end

    assert_raise ArgumentError, ~r/:headers must be/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.BadHeaders do
        @moduledoc false
        use LlmCall.Provider,
          base_url: "https://x.test",
          auth: :none,
          headers: ["bad"],
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)
    end
  end

  test "an alias inside a list option is expanded, not stored as AST" do
    modules =
      Code.compile_string("""
      defmodule LlmCall.TestCodec.AliasOptionProvider do
        @moduledoc false
        defmodule Pool do
          @moduledoc false
        end

        use LlmCall.Provider,
          base_url: "https://x.test",
          auth: :none,
          http_opts: [name: Pool],
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)

    {provider, _binary} =
      Enum.find(modules, fn {module, _} -> module == LlmCall.TestCodec.AliasOptionProvider end)

    assert provider.client(api_key: "k").http_opts == [
             name: LlmCall.TestCodec.AliasOptionProvider.Pool
           ]
  end

  test "a module attribute is not a literal and is rejected" do
    assert_raise ArgumentError, ~r/:base_url must be a literal/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.AttributeProvider do
        @moduledoc false
        @url "https://x.test"

        use LlmCall.Provider,
          base_url: @url,
          auth: :none,
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)
    end
  end

  test "a remote call is not a literal and is rejected" do
    assert_raise ArgumentError, ~r/:timeout must be a literal/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.DynamicTimeoutProvider do
        @moduledoc false
        use LlmCall.Provider,
          base_url: "https://x.test",
          auth: :none,
          timeout: :timer.seconds(90),
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)
    end
  end

  test "headers: nil is treated as no headers" do
    defmodule NoHeadersProvider do
      @moduledoc false
      use LlmCall.Provider,
        base_url: "https://x.test",
        auth: :none,
        headers: nil,
        codecs: [chat: LlmCall.TestCodec.Fake]
    end

    assert NoHeadersProvider.client(api_key: "k").headers == []
  end

  test "a function auth shape returns headers" do
    defmodule FunctionAuth do
      @moduledoc false
      def headers(key), do: [{"x-key", key}]
    end

    defmodule FunctionAuthProvider do
      @moduledoc false
      use LlmCall.Provider,
        base_url: "https://x.test",
        auth: {FunctionAuth, :headers},
        codecs: [chat: LlmCall.TestCodec.Fake]
    end

    assert FunctionAuthProvider.client(api_key: "k").headers == [{"x-key", "k"}]
  end

  test "client json_library: wins, then an explicit config:, then the declaration" do
    defmodule DeclarationJSON do
      @moduledoc false
      def encode(term), do: {:json, term}
      def decode(term), do: {:ok, term}

      use LlmCall.Provider,
        base_url: "https://x.test",
        auth: :none,
        json_library: __MODULE__,
        codecs: [chat: LlmCall.TestCodec.Fake]
    end

    defmodule OtherJSON do
      @moduledoc false
      def encode(term), do: {:other, term}
      def decode(term), do: {:ok, term}
    end

    assert %Client{config: %LlmCall.Config{json: DeclarationJSON}} = DeclarationJSON.client([])

    assert %Client{config: %LlmCall.Config{json: OtherJSON}} =
             DeclarationJSON.client(config: LlmCall.Config.new(json_library: OtherJSON))

    assert %Client{config: %LlmCall.Config{json: OtherJSON}} =
             DeclarationJSON.client(
               config: LlmCall.Config.new(json_library: DeclarationJSON),
               json_library: OtherJSON
             )
  end

  test "a non-list headers call option raises" do
    assert_raise ArgumentError, ~r/:headers must be a list/, fn ->
      TestProvider.client(api_key: "k", headers: 123)
    end
  end

  test "a non-string base_url is a compile error" do
    assert_raise ArgumentError, ~r/:base_url must be a string/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.BadBaseProvider do
        @moduledoc false
        use LlmCall.Provider,
          base_url: 123,
          auth: :none,
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)
    end
  end

  test "a client base_url must be an http(s) URL with a host" do
    for url <- ["api.openai.com", "ftp://example.test", "https://", "://bad"] do
      assert_raise ArgumentError, ~r/:base_url must be an http\(s\) URL/, fn ->
        TestProvider.client(api_key: "k", base_url: url)
      end
    end

    assert %Client{base_url: "https://api.example.test"} =
             TestProvider.client(api_key: "k", base_url: "https://api.example.test")
  end

  test "a non-list headers value is a compile error" do
    assert_raise ArgumentError, ~r/:headers must be a list/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.BadHeadersProvider do
        @moduledoc false
        use LlmCall.Provider,
          base_url: "https://x.test",
          auth: :none,
          headers: "authorization: x",
          codecs: [chat: LlmCall.TestCodec.Fake]
      end
      """)
    end
  end

  test "duplicate codec names are a compile error" do
    assert_raise ArgumentError, ~r/same codec name twice/, fn ->
      Code.compile_string("""
      defmodule LlmCall.TestCodec.DuplicateCodec do
        @moduledoc false
        use LlmCall.Provider,
          base_url: "https://x.test",
          auth: :none,
          codecs: [chat: LlmCall.TestCodec.Fake, chat: LlmCall.TestCodec.TextOnly]
      end
      """)
    end
  end

  test "per-call headers override client headers and codec headers still win" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    client = client(headers: [{"x-scope", "client"}, {"x-override", "client"}])

    assert {:ok, _response} =
             LlmCall.complete(client, request(),
               headers: [
                 {"x-scope", "call"},
                 {"x-override", "call"},
                 {"content-type", "text/plain"}
               ]
             )

    assert [sent] = TestHTTP.requests()
    assert {"x-scope", "call"} in sent.headers
    assert {"x-override", "call"} in sent.headers

    assert {"content-type", "text/plain"} in sent.headers
  end

  test "stream/3 accepts per-call headers" do
    TestHTTP.put_events([{:status, 200}, {:data, "data: {}\n\n"}])

    assert {:ok, stream} =
             LlmCall.stream(client(), request(), headers: [{"x-stream", "1"}])

    assert [_ | _] = Enum.to_list(stream)
    assert [sent] = TestHTTP.requests()
    assert {"x-stream", "1"} in sent.headers
  end

  test "malformed per-call headers are a validation error before any request" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.complete(client(), request(), headers: [{"x", 1}])

    assert message =~ "headers:"
    assert TestHTTP.requests() == []
  end

  test "a caller header replaces the provider header of the same name" do
    client = TestProvider.client(api_key: "k", headers: [{"Authorization", "Bearer override"}])

    assert [{"authorization", "Bearer override"}] =
             Enum.filter(client.headers, fn {name, _} -> name == "authorization" end)
  end

  test "the codec's protocol header replaces a caller header of the same name" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    client =
      LlmCall.Examples.OpenAI.client(
        api_key: "k",
        base_url: TestHTTP.url(),
        headers: [{"Content-Type", "text/plain"}]
      )

    {:ok, encoded} = LlmCall.encode(LlmCall.Dialect.OpenAI.Chat, request())
    assert {:ok, _} = LlmCall.execute(client, encoded)

    assert [sent] = TestHTTP.requests()

    assert [{"content-type", "application/json"}] =
             Enum.filter(sent.headers, fn {name, _} -> name == "content-type" end)
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
