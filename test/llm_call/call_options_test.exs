defmodule LlmCall.CallOptionsTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Content, EncodedRequest, Error, Message, Request}
  alias LlmCall.TestHTTPServer, as: TestHTTP

  setup do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}"}})
    :ok
  end

  defp client do
    LlmCall.TestProvider.client(api_key: "k", base_url: TestHTTP.url())
  end

  defp request do
    %Request{model: "m", messages: [%Message{role: :user, content: [%Content.Text{text: "x"}]}]}
  end

  defp media_request do
    %LlmCall.Media.Request{modality: :image, model: "m", prompt: "p"}
  end

  test "complete/3 rejects an unknown call option before any request" do
    for opts <- [[bogus: 1], [codc: :chat], %{codec: :chat}] do
      assert {:error, %Error{kind: :validation, message: message}} =
               LlmCall.complete(client(), request(), opts)

      assert message =~ "option" or message =~ "keyword"
    end

    assert TestHTTP.requests() == []
  end

  test "stream/3 rejects an unknown call option before any request" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.stream(client(), request(), codc: :chat)

    assert message =~ "unknown option :codc"
    assert message =~ ":on_event"
    assert TestHTTP.requests() == []
  end

  test "generate/3 rejects an unknown call option before any request" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.generate(client(), media_request(), codec: :chat, bogus: 1)

    assert message =~ "unknown option :bogus"
    assert TestHTTP.requests() == []
  end

  test "poll/3 rejects an unknown call option before any request" do
    encoded = %EncodedRequest{method: :get, path: "/poll"}

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.poll(client(), encoded, codec: :chat, bogus: 1)

    assert message =~ "unknown option :bogus"
    assert TestHTTP.requests() == []
  end

  test "the documented call options are accepted" do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})

    assert {:ok, _response} = LlmCall.complete(client(), request(), codec: :chat)

    TestHTTP.put_events([{:status, 200}, {:data, "data: [DONE]\n\n"}])

    assert {:ok, _stream} =
             LlmCall.stream(client(), request(), codec: :chat, on_event: fn _ -> :ok end)

    assert {:ok, _stream} =
             LlmCall.stream(client(), request(), codec: :chat, headers: [{"x-call", "1"}])
  end
end
