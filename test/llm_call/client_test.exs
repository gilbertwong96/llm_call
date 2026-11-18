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

  test "an undecodable error body is :transport with the status" do
    TestHTTP.put_response({:ok, %{status: 502, headers: [], body: "<html>"}})

    assert {:error, %Error{kind: :transport, status: 502}} = LlmCall.complete(client(), request())
  end

  test "a transport failure is :transport" do
    client = TestProvider.client(api_key: "secret", base_url: "http://127.0.0.1:1")

    assert {:error, %Error{kind: :transport, message: message}} =
             LlmCall.complete(client, request())

    assert message =~ "econnrefused"
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

  test "execute/2 decodes the body; fetch/2 returns bytes" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"a":1})}})

    encoded = %LlmCall.EncodedRequest{method: :get, path: "/asset", query: %{"x" => 1}}

    assert {:ok, %{status: 200, body: %{"a" => 1}}} = LlmCall.execute(client(), encoded)
    assert {:ok, %{status: 200, body: ~s({"a":1})}} = LlmCall.fetch(client(), encoded)

    sent = List.last(TestHTTP.requests())
    assert sent.path == "/asset?x=1"
  end

  test "an unencodable body is :validation, before any request" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}"}})

    encoded = %LlmCall.EncodedRequest{method: :post, path: "/x", body: %{"bad" => {1, 2}}}

    assert {:error, %Error{kind: :validation}} = LlmCall.execute(client(), encoded)
    assert TestHTTP.requests() == []
  end

  test "json: on the client reaches the boundary and the codec" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    client = client(json: MarkerJSON)

    assert %Client{config: %Config{json: MarkerJSON}} = client
    assert {:ok, %Response{}} = LlmCall.complete(client, request())

    assert [sent] = TestHTTP.requests()
    assert String.starts_with?(sent.body, "MARKER:")
  end

  test "http_opts and timeout are part of the client" do
    assert %Client{http_opts: [name: MyPool], timeout: 5_000} =
             client(http_opts: [name: MyPool], timeout: 5_000)
  end

  test "the documented example base URL composes the real endpoint" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    client = LlmCall.Examples.OpenAI.client(api_key: "k", base_url: TestHTTP.url())
    {:ok, encoded} = LlmCall.encode(LlmCall.Protocol.OpenAI.Chat, request())

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

  test "client json: wins, then an explicit config:, then the declaration" do
    defmodule DeclarationJSON do
      @moduledoc false
      def encode(term), do: {:json, term}
      def decode(term), do: {:ok, term}

      use LlmCall.Provider,
        base_url: "https://x.test",
        auth: :none,
        json: __MODULE__,
        codecs: [chat: LlmCall.TestCodec.Fake]
    end

    defmodule OtherJSON do
      @moduledoc false
      def encode(term), do: {:other, term}
      def decode(term), do: {:ok, term}
    end

    assert %Client{config: %LlmCall.Config{json: DeclarationJSON}} = DeclarationJSON.client([])

    assert %Client{config: %LlmCall.Config{json: OtherJSON}} =
             DeclarationJSON.client(config: LlmCall.Config.new(json: OtherJSON))

    assert %Client{config: %LlmCall.Config{json: OtherJSON}} =
             DeclarationJSON.client(
               config: LlmCall.Config.new(json: DeclarationJSON),
               json: OtherJSON
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

    {:ok, encoded} = LlmCall.encode(LlmCall.Protocol.OpenAI.Chat, request())
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
