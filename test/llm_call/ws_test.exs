defmodule LlmCall.WSTest do
  use ExUnit.Case, async: true

  alias LlmCall.TestHTTPServer
  alias LlmCall.TestWSServer, as: Server
  alias LlmCall.WS.Mint

  setup do
    server = Server.start()
    on_exit(&Server.stop/0)
    {:ok, server: server}
  end

  test "connects, sends text and receives the echo" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000)
    assert {:ok, conn} = Mint.send_frame(conn, {:text, "hello"})
    assert {:ok, {:text, "hello"}, conn} = Mint.recv(conn, 2_000)
    assert :ok = Mint.close(conn)
  end

  test "binary frames round-trip" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000)
    assert {:ok, conn} = Mint.send_frame(conn, {:binary, <<1, 2, 3>>})
    assert {:ok, {:binary, <<1, 2, 3>>}, conn} = Mint.recv(conn, 2_000)
    Mint.close(conn)
  end

  test "answers a ping and skips it while waiting for data" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000)

    Server.send_frame({:ping, "x"})
    Server.send_frame({:text, "after"})

    assert {:ok, {:text, "after"}, conn} = Mint.recv(conn, 2_000)

    {server, _port} = Process.get(:llm_call_test_ws_server)
    Process.sleep(50)
    send(server, {:pongs, self()})
    assert_receive {:pongs, pongs}, 2_000
    assert {:pong, "x"} in pongs

    Mint.close(conn)
  end

  test "reports a peer close with its code and reason" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000)
    Server.close(1001, "bye")
    assert {:ok, {:close, 1001, "bye"}, _conn} = Mint.recv(conn, 2_000)
  end

  test "reassembles fragmented server frames" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000)
    Server.send_fragments(["hel", "lo"])

    assert {:ok, {:text, "hello"}, conn} = Mint.recv(conn, 2_000)
    Mint.close(conn)
  end

  test "feed/2 decodes frames from an active-mode socket message" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000)
    Server.send_frames([{:text, "one"}, {:text, "two"}])

    message = next_message()
    assert {:ok, [{:text, "one"}, {:text, "two"}], conn} = Mint.feed(conn, message)
    Mint.close(conn)
  end

  test "feed/2 drains frames buffered by recv/2 before new ones" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000)
    Server.send_frames([{:text, "one"}, {:text, "two"}])

    assert {:ok, {:text, "one"}, conn} = Mint.recv(conn, 2_000)

    Server.send_frame({:text, "three"})
    message = next_message()

    assert {:ok, [{:text, "two"}, {:text, "three"}], conn} = Mint.feed(conn, message)
    Mint.close(conn)
  end

  test "close/3 completes the close handshake" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000)
    Server.close(1001, "bye")

    assert {:ok, {:close, 1001, "bye"}, conn} = Mint.recv(conn, 2_000)
    assert :ok = Mint.close(conn, 1001, "bye")

    assert eventually(fn -> Server.close_ack() == {1001, "bye"} end)
  end

  test "times out when no frame arrives" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000)
    assert {:error, :timeout} = Mint.recv(conn, 20)
    Mint.close(conn)
  end

  test "rejects a non-WebSocket URL" do
    assert {:error, {:invalid_url, "https://example.test"}} =
             Mint.connect("https://example.test", [], [])
  end

  defp next_message do
    receive do
      message -> message
    after
      2_000 -> flunk("the server did not deliver a socket message")
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  test "rejects a failed upgrade" do
    TestHTTPServer.start()
    on_exit(&TestHTTPServer.stop/0)

    assert {:error, {:upgrade_failed, 200}} =
             Mint.connect(String.replace(TestHTTPServer.url(), "http", "ws"), [], timeout: 2_000)
  end
end
