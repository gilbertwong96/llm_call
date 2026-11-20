defmodule LlmCall.TransportReasonTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Content, Error, Message, Request}
  alias LlmCall.TestHTTPServer, as: TestHTTP

  defp request do
    %Request{model: "m", messages: [%Message{role: :user, content: [%Content.Text{text: "x"}]}]}
  end

  test "an unknown pool is a structured reason" do
    client =
      LlmCall.TestProvider.client(
        api_key: "k",
        base_url: "http://127.0.0.1:1",
        http_opts: [name: LlmCall.NoSuchPool]
      )

    assert {:error, %Error{kind: :transport, reason: reason, message: message}} =
             LlmCall.complete(client, request())

    assert reason == {:unknown_pool, LlmCall.NoSuchPool}
    assert message == "unknown pool: LlmCall.NoSuchPool"
  end

  test "a connection failure carries the transport reason, not the struct" do
    client = LlmCall.TestProvider.client(api_key: "k", base_url: "http://127.0.0.1:1")

    assert {:error, %Error{kind: :transport, reason: reason, message: message}} =
             LlmCall.complete(client, request())

    assert reason == :econnrefused
    assert message == "transport error: connection refused"
  end

  test "a timeout carries :timeout" do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}", delay: 200}})

    client =
      LlmCall.TestProvider.client(
        api_key: "k",
        base_url: TestHTTP.url(),
        timeout: 50
      )

    assert {:error, %Error{kind: :transport, reason: reason, message: message}} =
             LlmCall.complete(client, request())

    assert reason == :timeout
    assert message == "transport error: timeout"
  end

  test "an HTTP status failure has no reason" do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    TestHTTP.put_response({:ok, %{status: 503, headers: [], body: ""}})

    client = LlmCall.TestProvider.client(api_key: "k", base_url: TestHTTP.url())
    encoded = %LlmCall.EncodedRequest{method: :get, path: "/asset"}

    assert {:error, %Error{kind: :transport, status: 503, reason: nil}} =
             LlmCall.execute(client, encoded)
  end

  test "a provider error has no reason" do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    TestHTTP.put_response({:ok, %{status: 401, headers: [], body: ~s({"error":{"message":"x"}})}})

    client = LlmCall.TestProvider.client(api_key: "k", base_url: TestHTTP.url())

    assert {:error, %Error{kind: :provider, status: 401, reason: nil}} =
             LlmCall.complete(client, request())
  end

  describe "over the Responses WebSocket" do
    alias LlmCall.Protocol.OpenAI.Responses.Connection

    setup do
      LlmCall.TestWSServer.start(mode: :hold)
      on_exit(&LlmCall.TestWSServer.stop/0)

      client = %LlmCall.Client{
        provider: LlmCall.TestProvider,
        codecs: %{chat: LlmCall.Protocol.OpenAI.Responses},
        base_url: String.replace(LlmCall.TestWSServer.url(), "ws://", "http://"),
        headers: [],
        http_opts: [],
        timeout: 5_000,
        config: %LlmCall.Config{}
      }

      {:ok, connection} =
        Connection.start_link(client: client, ws_opts: [timeout: 2_000], max_age_ms: 60_000)

      on_exit(fn -> if Process.alive?(connection), do: Connection.close(connection) end)
      {:ok, connection: connection}
    end

    test "an interrupted lane reports its reason", %{connection: connection} do
      {:ok, stream} = Connection.create(connection, request(), stream_id: "main")
      :ok = Connection.reconnect(connection)

      exception = assert_raise LlmCall.WS.Error, fn -> Enum.to_list(stream) end

      assert %Error{kind: :transport, reason: {:interrupted, :reconnected}, message: message} =
               LlmCall.WS.Error.error(exception)

      assert message ==
               "responses connection: the in-flight response was interrupted (reconnected)"
    end

    test "create while disconnected reports :disconnected", %{connection: connection} do
      LlmCall.TestWSServer.stop()
      Process.sleep(100)

      assert {:error, %Error{kind: :transport, reason: :disconnected}} =
               Connection.create(connection, request(), stream_id: "later")
    end
  end
end
