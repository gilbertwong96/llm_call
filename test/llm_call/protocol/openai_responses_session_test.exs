defmodule LlmCall.Protocol.OpenAIResponsesSessionTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Error, TestWSServer}

  alias LlmCall.Protocol.OpenAI.Responses.Session

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
    Session.start_link(
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
    {:ok, session} = start()

    assert {:ok, stream} = Session.create(session, request(), stream_id: "main")

    assert types(stream) == [
             :message_start,
             :content_start,
             :text_delta,
             :content_stop,
             :message_delta,
             :message_stop
           ]

    Session.close(session)
  end

  test "the wire create event carries the type, lane and no stream flag" do
    {:ok, session} = start()

    assert {:ok, _stream} = Session.create(session, request(), stream_id: "main")

    create = await_event("response.create")

    assert create["stream_id"] == "main"
    refute Map.has_key?(create, "stream")
    assert is_list(create["input"])
  end

  test "a stream_id is generated when omitted" do
    {:ok, session} = start()

    assert {:ok, stream} = Session.create(session, request())

    assert String.starts_with?(stream.stream_id, "lane-")
    assert :ok == Session.cancel(session, stream.stream_id)
  end

  test "two lanes are decoded independently" do
    {:ok, session} = start()

    assert {:ok, first} = Session.create(session, request(), stream_id: "first")
    assert {:ok, second} = Session.create(session, request(), stream_id: "second")

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

    Session.close(session)
  end

  test "invalid and duplicate stream ids are typed errors" do
    TestWSServer.set_mode(:hold)
    {:ok, session} = start()

    assert {:error, %Error{kind: :validation}} =
             Session.create(session, request(), stream_id: "bad id")

    assert {:ok, _stream} = Session.create(session, request(), stream_id: "main")

    assert {:error, %Error{kind: :validation, message: message}} =
             Session.create(session, request(), stream_id: "main")

    assert message =~ "already in use"
    Session.close(session)
  end

  test "steer sends a response.steer event for the lane" do
    TestWSServer.set_mode(:hold)
    {:ok, session} = start()
    {:ok, _stream} = Session.create(session, request(), stream_id: "main")

    assert :ok = Session.steer(session, "main", "stop here")

    steer = await_event("response.steer")
    assert steer["stream_id"] == "main"
    assert steer["input"] == "stop here"

    Session.close(session)
  end

  test "reconnect interrupts in-flight lanes and accepts new work" do
    TestWSServer.set_mode(:hold)
    {:ok, session} = start()
    {:ok, stream} = Session.create(session, request(), stream_id: "main")

    assert :ok = Session.reconnect(session)

    assert_raise LlmCall.WS.Error, fn -> Enum.to_list(stream) end

    TestWSServer.set_mode(:responses)
    assert {:ok, stream} = Session.create(session, request(), stream_id: "after")

    assert types(stream) == [
             :message_start,
             :content_start,
             :text_delta,
             :content_stop,
             :message_delta,
             :message_stop
           ]

    Session.close(session)
  end

  test "cancelling a lane sends response.cancel and ends the stream" do
    TestWSServer.set_mode(:hold)
    {:ok, session} = start()
    {:ok, stream} = Session.create(session, request(), stream_id: "main")

    assert :ok = Session.cancel(session, "main")
    assert Enum.to_list(stream) == []

    cancel = await_event("response.cancel")
    assert cancel["stream_id"] == "main"

    Session.close(session)
  end

  test "a missing client is rejected at start" do
    Process.flag(:trap_exit, true)
    assert {:error, :client_required} = Session.start_link(client: nil)
  end
end
