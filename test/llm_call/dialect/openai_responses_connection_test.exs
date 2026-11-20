defmodule LlmCall.Dialect.OpenAIResponsesConnectionTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Error, TestWSServer}

  alias LlmCall.Dialect.OpenAI.Responses.Connection

  defmodule FailingSendWS do
    @moduledoc false
    @behaviour LlmCall.WS

    @impl true
    def connect(_url, _headers, _opts), do: {:ok, :conn}

    @impl true
    def send_frame(:conn, _frame), do: {:error, :closed}

    @impl true
    def feed(:conn, _message), do: {:ok, [], :conn}

    @impl true
    def recv(:conn, _timeout), do: {:error, :timeout}

    @impl true
    def close(_conn, _code, _reason), do: :ok
  end

  defmodule HeadersWS do
    @moduledoc false
    @behaviour LlmCall.WS

    @impl true
    def connect(url, headers, opts) do
      send(opts[:test_pid], {:connect, url, headers})
      {:ok, :conn}
    end

    @impl true
    def send_frame(:conn, _frame), do: {:ok, :conn}

    @impl true
    def feed(:conn, _message), do: {:ok, [], :conn}

    @impl true
    def recv(:conn, _timeout), do: {:error, :timeout}

    @impl true
    def close(_conn, _code, _reason), do: :ok
  end

  defmodule WSProvider do
    @moduledoc "Provider pointing at the local test WebSocket server."

    use LlmCall.Provider,
      base_url: "http://127.0.0.1",
      auth: :bearer,
      codecs: [chat: LlmCall.Dialect.OpenAI.Responses]
  end

  setup do
    TestWSServer.start(mode: :responses)
    on_exit(&TestWSServer.stop/0)
    :ok
  end

  defp client do
    WSProvider.client(
      api_key: "secret",
      base_url: String.replace(TestWSServer.url(), "ws://", "http://")
    )
  end

  defp request do
    %LlmCall.Request{
      model: "gpt-4.1",
      messages: [%LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "hi"}]}]
    }
  end

  defp start(opts \\ []) do
    Connection.start_link(
      Keyword.merge([client: client(), ws_opts: [timeout: 2_000], max_age_ms: 60_000], opts)
    )
  end

  defp types(stream), do: Enum.map(Enum.to_list(stream), & &1.type)

  defp text_frames do
    for {:text, data} <- TestWSServer.frames() do
      {:ok, event} = LlmCall.JSON.decode(data)
      event
    end
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end

  defp await_event(type, attempts \\ 100) do
    case Enum.find(text_frames(), &(&1["type"] == type)) do
      nil when attempts > 0 ->
        Process.sleep(10)
        await_event(type, attempts - 1)

      nil ->
        flunk("the test server never received a #{type} frame")

      event ->
        event
    end
  end

  test "create/3 sends response.create and streams decoded events" do
    {:ok, connection} = start()

    assert {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    assert types(stream) == [
             :message_start,
             :content_start,
             :text_delta,
             :content_stop,
             :message_delta,
             :message_stop
           ]

    Connection.close(connection)
  end

  test "response_id/2 exposes the id needed for previous_response_id" do
    {:ok, connection} = start()
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    assert [_ | _] = Enum.to_list(stream)
    assert {:ok, "resp_main"} = Connection.response_id(connection, "main")
    assert :error = Connection.response_id(connection, "missing")

    Connection.close(connection)
  end

  test "response_id keeps the most recent 32 finished lanes" do
    {:ok, connection} = start()

    for n <- 1..33 do
      stream_id = "lane-#{n}"
      {:ok, stream} = Connection.create(connection, request(), stream_id: stream_id)
      assert [_ | _] = Enum.to_list(stream)
    end

    assert {:ok, "resp_lane-33"} = Connection.response_id(connection, "lane-33")
    assert :error = Connection.response_id(connection, "lane-1")

    Connection.close(connection)
  end

  test "an event for an unknown lane does not tear down the connection" do
    {:ok, connection} = start()
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")
    assert [_ | _] = Enum.to_list(stream)

    {:ok, ghost} =
      LlmCall.JSON.encode(%{
        "type" => "response.output_text.delta",
        "stream_id" => "ghost",
        "output_index" => 0,
        "delta" => "ignored"
      })

    TestWSServer.send_frame({:text, ghost})
    Process.sleep(20)

    assert {:ok, next} = Connection.create(connection, request(), stream_id: "next")
    assert [_ | _] = Enum.to_list(next)

    Connection.close(connection)
  end

  test "the wire create event carries the type, lane and no stream flag" do
    {:ok, connection} = start()

    assert {:ok, _stream} = Connection.create(connection, request(), stream_id: "main")

    create = await_event("response.create")

    assert create["stream_id"] == "main"
    refute Map.has_key?(create, "stream")
    assert is_list(create["input"])
  end

  test "a stream_id is generated when omitted" do
    {:ok, connection} = start()

    assert {:ok, stream} = Connection.create(connection, request())

    assert String.starts_with?(stream.stream_id, "lane-")
    assert :ok == Connection.cancel(connection, stream.stream_id)
  end

  test "two lanes are decoded independently when the server echoes stream_id" do
    TestWSServer.stop()
    TestWSServer.start(mode: :responses, echo_stream_id: true)

    {:ok, connection} = start()

    assert {:ok, first} = Connection.create(connection, request(), stream_id: "first")
    assert {:ok, second} = Connection.create(connection, request(), stream_id: "second")

    assert types(first) == [
             :message_start,
             :content_start,
             :text_delta,
             :content_stop,
             :message_delta,
             :message_stop
           ]

    assert types(second) == [
             :message_start,
             :content_start,
             :text_delta,
             :content_stop,
             :message_delta,
             :message_stop
           ]

    Connection.close(connection)
  end

  test "a lane is released when its subscriber dies" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, _stream} = Connection.create(connection, request(), stream_id: "gone")
        send(parent, :created)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :created
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert eventually(fn ->
             match?({:ok, _stream}, Connection.create(connection, request(), stream_id: "gone"))
           end)

    Connection.close(connection)
  end

  test "invalid and duplicate stream ids are typed errors" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()

    assert {:error, %Error{kind: :validation}} =
             Connection.create(connection, request(), stream_id: "bad id")

    assert {:ok, _stream} = Connection.create(connection, request(), stream_id: "main")

    assert {:error, %Error{kind: :validation, message: message}} =
             Connection.create(connection, request(), stream_id: "main")

    assert message =~ "already in use"
    Connection.close(connection)
  end

  test "malformed create options are a typed error and keep the connection alive" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()

    for opts <- [nil, %{}, "x", [:not_a_tuple], [bogus: 1]] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Connection.create(connection, request(), opts)

      assert is_binary(message)
    end

    assert {:ok, _stream} = Connection.create(connection, request(), stream_id: "main")
    Connection.close(connection)
  end

  test "steer routes by the lane's response id, not by stream_id" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    {:ok, _stream} = Connection.create(connection, request(), stream_id: "main")

    assert eventually(fn -> match?({:ok, _}, Connection.response_id(connection, "main")) end)
    assert :ok = Connection.steer(connection, "main", "stop here")

    steer = await_event("response.steer")
    assert steer["previous_response_id"] == "resp_main"
    refute Map.has_key?(steer, "stream_id")
    assert steer["input"] == "stop here"

    Connection.close(connection)
  end

  test "steer before response.created is a validation error, not an untenanted event" do
    TestWSServer.set_mode(:silent)
    {:ok, connection} = start()
    {:ok, _stream} = Connection.create(connection, request(), stream_id: "main")

    assert {:error, %Error{kind: :validation, message: message}} =
             Connection.steer(connection, "main", "stop here")

    assert message =~ "no response id"

    Connection.close(connection)
  end

  test "a second concurrent lane is refused once the server proves it does not echo stream_id" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    {:ok, _stream} = Connection.create(connection, request(), stream_id: "lane-a")

    assert eventually(fn -> match?({:ok, _}, Connection.response_id(connection, "lane-a")) end)

    assert {:error, %Error{kind: :validation, message: message}} =
             Connection.create(connection, request(), stream_id: "lane-b")

    assert message =~ "does not echo stream_id"

    Connection.close(connection)
  end

  test "back-to-back creates are allowed before any event has been decoded" do
    TestWSServer.set_mode(:silent)
    {:ok, connection} = start()

    assert {:ok, first} = Connection.create(connection, request(), stream_id: "lane-a")
    assert {:ok, second} = Connection.create(connection, request(), stream_id: "lane-b")
    assert first.stream_id == "lane-a"
    assert second.stream_id == "lane-b"

    Connection.close(connection)
  end

  test "a server that echoes stream_id runs two lanes at once" do
    TestWSServer.stop()
    TestWSServer.start(mode: :hold, echo_stream_id: true)

    {:ok, connection} = start()

    assert {:ok, _first} = Connection.create(connection, request(), stream_id: "lane-a")
    assert {:ok, _second} = Connection.create(connection, request(), stream_id: "lane-b")
    assert eventually(fn -> match?({:ok, _}, Connection.response_id(connection, "lane-a")) end)
    assert eventually(fn -> match?({:ok, _}, Connection.response_id(connection, "lane-b")) end)

    assert {:ok, _third} = Connection.create(connection, request(), stream_id: "lane-c")
    assert eventually(fn -> match?({:ok, _}, Connection.response_id(connection, "lane-c")) end)

    Connection.close(connection)
  end

  test "reconnect interrupts in-flight lanes and accepts new work" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    assert :ok = Connection.reconnect(connection)

    exception = assert_raise LlmCall.WS.Error, fn -> Enum.to_list(stream) end

    assert %Error{kind: :transport, message: message} = LlmCall.WS.Error.error(exception)
    assert message =~ "interrupted"

    TestWSServer.set_mode(:responses)
    assert {:ok, stream} = Connection.create(connection, request(), stream_id: "after")

    assert types(stream) == [
             :message_start,
             :content_start,
             :text_delta,
             :content_stop,
             :message_delta,
             :message_stop
           ]

    Connection.close(connection)
  end

  test "cancelling a lane sends response.cancel for its response id and ends the stream" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    assert eventually(fn -> match?({:ok, _}, Connection.response_id(connection, "main")) end)
    assert :ok = Connection.cancel(connection, "main")
    assert types(stream) == [:message_start]

    cancel = await_event("response.cancel")
    assert cancel["response_id"] == "resp_main"
    refute Map.has_key?(cancel, "stream_id")

    Connection.close(connection)
  end

  test "a failed reconnect keeps the connection alive and rejects work" do
    {:ok, connection} = start(max_reconnect_attempts: 1, retry_delay_ms: 20)

    TestWSServer.stop()

    assert {:error, %Error{kind: :transport}} = Connection.reconnect(connection)
    assert Process.alive?(connection)

    assert {:error, %Error{kind: :transport, message: message}} =
             Connection.create(connection, request())

    assert message =~ "disconnected"

    Connection.close(connection)
  end

  test "retries with backoff and recovers when the server returns" do
    port = TestWSServer.port()
    {:ok, connection} = start(max_reconnect_attempts: 10, retry_delay_ms: 20)

    TestWSServer.stop()
    Process.sleep(40)
    TestWSServer.start(port: port, mode: :responses)

    assert eventually(fn ->
             match?(
               {:ok, _stream},
               Connection.create(connection, request(), stream_id: "recovered")
             )
           end)

    :ok = Connection.cancel(connection, "recovered")
    Connection.close(connection)
  end

  test "reconnect: false stops the connection when the socket closes" do
    Process.flag(:trap_exit, true)
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start(reconnect: false)
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    TestWSServer.stop()

    assert eventually(fn -> not Process.alive?(connection) end)
    assert_raise LlmCall.WS.Error, fn -> Enum.to_list(stream) end
  end

  test "max_age reconnects and interrupts in-flight lanes" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start(max_age_ms: 50, retry_delay_ms: 20)
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    assert_raise LlmCall.WS.Error, fn -> Enum.to_list(stream) end

    TestWSServer.set_mode(:responses)
    assert {:ok, next} = Connection.create(connection, request(), stream_id: "after")

    assert types(next) == [
             :message_start,
             :content_start,
             :text_delta,
             :content_stop,
             :message_delta,
             :message_stop
           ]

    Connection.close(connection)
  end

  test "a stream must be reduced by the process that created it" do
    {:ok, connection} = start()
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")
    parent = self()

    spawn(fn ->
      result =
        try do
          Enum.to_list(stream)
          :ok
        rescue
          error -> {:raised, error.__struct__}
        end

      send(parent, {:result, result})
    end)

    assert_receive {:result, {:raised, ArgumentError}}, 2_000
    Connection.close(connection)
  end

  test "a write failure marks the connection disconnected" do
    {:ok, connection} =
      Connection.start_link(
        client: client(),
        ws: FailingSendWS,
        ws_opts: []
      )

    assert {:error, %Error{kind: :transport}} =
             Connection.create(connection, request(), stream_id: "main")

    assert {:error, %Error{kind: :transport, message: message}} =
             Connection.create(connection, request())

    assert message =~ "disconnected"

    Connection.close(connection)
  end

  test "halting a stream unsubscribes the lane" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    assert [%LlmCall.StreamEvent{}] = Enum.take(stream, 1)

    assert eventually(fn ->
             match?(
               {:ok, _stream},
               Connection.create(connection, request(), stream_id: "main")
             )
           end)

    Connection.close(connection)
  end

  test "stale timer references are ignored" do
    {:ok, connection} = start()

    send(connection, {:retry, make_ref()})
    send(connection, {:max_age, make_ref()})
    Process.sleep(20)

    assert Process.alive?(connection)
    assert {:ok, stream} = Connection.create(connection, request(), stream_id: "main")
    assert [_ | _] = Enum.to_list(stream)

    Connection.close(connection)
  end

  test "max_age with reconnect: false stops the connection" do
    Process.flag(:trap_exit, true)
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start(max_age_ms: 30, reconnect: false)
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    assert eventually(fn -> not Process.alive?(connection) end)
    assert_raise LlmCall.WS.Error, fn -> Enum.to_list(stream) end
  end

  test "cancelling a lane keeps its response id" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    {:ok, _stream} = Connection.create(connection, request(), stream_id: "main")

    assert eventually(fn -> match?({:ok, _}, Connection.response_id(connection, "main")) end)
    assert :ok = Connection.cancel(connection, "main")
    assert {:ok, "resp_main"} = Connection.response_id(connection, "main")

    Connection.close(connection)
  end

  test "handshake headers merge the client headers with the connection headers" do
    {:ok, connection} =
      Connection.start_link(
        client: client(),
        ws: HeadersWS,
        ws_opts: [test_pid: self()],
        headers: [{"x-call", "1"}]
      )

    assert_receive {:connect, _url, headers}
    assert {"authorization", "Bearer secret"} in headers
    assert {"x-call", "1"} in headers

    Connection.close(connection)
  end

  test "a missing client is rejected at start" do
    Process.flag(:trap_exit, true)
    assert {:error, :client_required} = Connection.start_link(client: nil)
  end
end
