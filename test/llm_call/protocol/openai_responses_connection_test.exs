defmodule LlmCall.Protocol.OpenAIResponsesConnectionTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Error, TestWSServer}

  alias LlmCall.Protocol.OpenAI.Responses.Connection

  defmodule WSProvider do
    @moduledoc "Provider pointing at the local test WebSocket server."

    use LlmCall.Provider,
      base_url: "http://127.0.0.1",
      auth: :bearer,
      codecs: [chat: LlmCall.Protocol.OpenAI.Responses]
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

  test "two lanes are decoded independently" do
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

  test "steer sends a response.steer event for the lane" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    {:ok, _stream} = Connection.create(connection, request(), stream_id: "main")

    assert :ok = Connection.steer(connection, "main", "stop here")

    steer = await_event("response.steer")
    assert steer["stream_id"] == "main"
    assert steer["input"] == "stop here"

    Connection.close(connection)
  end

  test "reconnect interrupts in-flight lanes and accepts new work" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    assert :ok = Connection.reconnect(connection)

    assert_raise LlmCall.WS.Error, fn -> Enum.to_list(stream) end

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

  test "cancelling a lane sends response.cancel and ends the stream" do
    TestWSServer.set_mode(:hold)
    {:ok, connection} = start()
    {:ok, stream} = Connection.create(connection, request(), stream_id: "main")

    assert :ok = Connection.cancel(connection, "main")
    assert Enum.to_list(stream) == []

    cancel = await_event("response.cancel")
    assert cancel["stream_id"] == "main"

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

  test "a missing client is rejected at start" do
    Process.flag(:trap_exit, true)
    assert {:error, :client_required} = Connection.start_link(client: nil)
  end
end
