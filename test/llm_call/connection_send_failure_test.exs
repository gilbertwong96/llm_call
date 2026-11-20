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

    @impl true
    def connect(_url, _headers, _opts), do: {:ok, :conn}

    @impl true
    def send_frame(:conn, _frame) do
      if Process.get({__MODULE__, :sent?}) do
        raise "socket exploded"
      else
        Process.put({__MODULE__, :sent?}, true)
        {:ok, :conn}
      end
    end

    @impl true
    def feed(:conn, _message), do: {:ok, [], :conn}

    @impl true
    def recv(_conn, _timeout), do: {:error, :timeout}

    @impl true
    def close(_conn, _code, _reason), do: :ok
  end

  defp client do
    %LlmCall.Client{
      provider: LlmCall.TestProvider,
      codecs: %{chat: LlmCall.Dialect.OpenAI.Responses},
      base_url: "http://127.0.0.1:1",
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

  defp start(ws) do
    Connection.start_link(client: client(), ws: ws, max_age_ms: 60_000)
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
    {:ok, connection} = start(RaisingLaterWS)
    assert {:ok, _stream} = Connection.create(connection, request(), stream_id: "main")

    assert {:error, %Error{kind: :transport, message: message}} =
             Connection.steer(connection, "main", "stop")

    assert message =~ "socket exploded"
    assert Process.alive?(connection)

    Connection.close(connection)
  end
end
