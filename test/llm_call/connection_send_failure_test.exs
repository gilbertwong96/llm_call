defmodule LlmCall.ConnectionSendFailureTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Content, Error, Message, Request}
  alias LlmCall.Dialect.OpenAI.Responses.Connection

  defmodule RaisingSendWS do
    @moduledoc false
    @behaviour LlmCall.WS

    @impl true
    def connect(_url, _headers, _opts), do: {:ok, :conn}

    @impl true
    def send_frame(:conn, _frame), do: raise("socket exploded")

    @impl true
    def feed(:conn, _message), do: {:ok, [], :conn}

    @impl true
    def recv(_conn, _timeout), do: {:error, :timeout}

    @impl true
    def close(_conn, _code, _reason), do: :ok
  end

  defmodule RaisingLaterWS do
    @moduledoc false
    @behaviour LlmCall.WS

    # A real connection, so the lane can receive `response.created`; the second
    # send raises, which is the failure a steer must survive.

    @impl true
    def connect(url, headers, opts), do: LlmCall.WS.Mint.connect(url, headers, opts)

    @impl true
    def send_frame(conn, frame) do
      if Process.get({__MODULE__, :sent?}) do
        raise "socket exploded"
      else
        Process.put({__MODULE__, :sent?}, true)
        LlmCall.WS.Mint.send_frame(conn, frame)
      end
    end

    @impl true
    def feed(conn, message), do: LlmCall.WS.Mint.feed(conn, message)

    @impl true
    def recv(conn, timeout), do: LlmCall.WS.Mint.recv(conn, timeout)

    @impl true
    def close(conn, code, reason), do: LlmCall.WS.Mint.close(conn, code, reason)
  end

  defp client(base_url) do
    %LlmCall.Client{
      provider: LlmCall.TestProvider,
      codecs: %{chat: LlmCall.Dialect.OpenAI.Responses},
      base_url: base_url,
      headers: [],
      http_opts: [],
      timeout: 5_000,
      config: %Config{}
    }
  end

  defp request do
    %Request{
      model: "gpt-4.1",
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }
  end

  defp start(ws, base_url \\ "http://127.0.0.1:1") do
    Connection.start_link(client: client(base_url), ws: ws, max_age_ms: 60_000)
  end

  test "a raising send_frame is a transport error, not a dead connection" do
    {:ok, connection} = start(RaisingSendWS)

    assert {:error, %Error{kind: :transport, message: message}} =
             Connection.create(connection, request(), stream_id: "main")

    assert message =~ "socket exploded"
    assert Process.alive?(connection)

    assert {:error, %Error{kind: :transport}} =
             Connection.create(connection, request(), stream_id: "second")

    Connection.close(connection)
  end

  test "a raising send_frame during steer keeps the connection alive" do
    LlmCall.TestWSServer.start(mode: :hold)
    on_exit(&LlmCall.TestWSServer.stop/0)

    base_url = "http://127.0.0.1:" <> Integer.to_string(LlmCall.TestWSServer.port())
    {:ok, connection} = start(RaisingLaterWS, base_url)
    assert {:ok, _stream} = Connection.create(connection, request(), stream_id: "main")

    assert eventually(fn -> match?({:ok, _}, Connection.response_id(connection, "main")) end)

    assert {:error, %Error{kind: :transport, message: message}} =
             Connection.steer(connection, "main", "stop")

    assert message =~ "socket exploded"
    assert Process.alive?(connection)

    Connection.close(connection)
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end
end
