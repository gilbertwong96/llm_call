defmodule LlmCall.StreamTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Error, HTTP, Request, StreamEvent}
  alias LlmCall.HTTP.Test, as: FakeHTTP

  defmodule StreamingCodec do
    @moduledoc "Codec fake whose stream is driven by JSON payloads."

    @behaviour LlmCall.Codec

    alias LlmCall.{Capabilities, Codec, EncodedRequest, Error, Response, StreamEvent, StreamState}
    alias LlmCall.StreamDelta

    @impl true
    def info, do: %Codec.Info{name: :streaming, protocol: :streaming, ir_version: 1}

    @impl true
    def validate_request(_request, _config), do: :ok

    @impl true
    def encode_request(_request, _config),
      do: {:ok, %EncodedRequest{method: :post, path: "/stream", body: %{"stream" => true}}}

    @impl true
    def decode_response(%{"text" => text}, _config),
      do: {:ok, %Response{content: [%LlmCall.Content.Text{text: text}]}}

    def decode_response(_term, _config),
      do: {:error, %Error{kind: :invalid_response, message: "bad"}}

    @impl true
    def decode_error(%{"error" => %{"message" => message}}, _config),
      do: %Error{kind: :provider, message: message}

    def decode_error(_term, _config), do: %Error{kind: :invalid_response, message: "bad"}

    @impl true
    def capabilities(_request, _config), do: %Capabilities{streaming: true}

    @impl true
    def init_stream(_request, _config), do: {:ok, StreamState.new(__MODULE__, %{})}

    @impl true
    def decode_stream_event(%{"text" => text}, _config, state),
      do: {:ok, [%StreamEvent{type: :text_delta, delta: %StreamDelta.Text{text: text}}], state}

    def decode_stream_event("DONE", _config, state), do: {:done, state}
    def decode_stream_event(_term, _config, state), do: {:ok, [], state}

    @impl true
    def finish_stream(state, _config),
      do: {:ok, [%StreamEvent{type: :message_stop}], state}
  end

  defmodule StreamingProvider do
    @moduledoc "Provider for the streaming tests."

    use LlmCall.Provider,
      base_url: "https://api.example.test",
      auth: :none,
      codecs: [chat: LlmCall.StreamTest.StreamingCodec]
  end

  defp client(opts \\ []), do: StreamingProvider.client(Keyword.merge([http: FakeHTTP], opts))

  defp request do
    %Request{
      model: "s",
      messages: [%LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "hi"}]}]
    }
  end

  defp sse(payload), do: "data: #{payload}\n\n"

  test "a transport failure mid-body raises LlmCall.HTTP.Error" do
    defmodule FailingStreamHTTP do
      @moduledoc false
      @behaviour LlmCall.HTTP
      @impl true
      def request(_request, _opts), do: {:ok, %{status: 200, headers: [], body: "{}"}}
      @impl true
      def stream(_request, acc, fun, _opts) do
        {:cont, acc} = fun.({:status, 200}, acc)
        {:error, :closed, acc}
      end
    end

    defmodule FailingStreamProvider do
      @moduledoc false
      use LlmCall.Provider,
        base_url: "https://x.test",
        auth: :none,
        http: LlmCall.StreamTest.FailingStreamHTTP,
        codecs: [chat: LlmCall.StreamTest.StreamingCodec]
    end

    {:ok, stream} = LlmCall.stream(FailingStreamProvider.client(), request())

    exception = assert_raise HTTP.Error, fn -> Enum.to_list(stream) end
    assert %Error{kind: :transport, message: message} = HTTP.Error.error(exception)
    assert message =~ "closed"
  end

  test "an adapter that never sends a status is treated as success" do
    defmodule NoStatusHTTP do
      @moduledoc false
      @behaviour LlmCall.HTTP
      @impl true
      def request(_request, _opts), do: {:ok, %{status: 200, headers: [], body: "{}"}}
      @impl true
      def stream(_request, acc, fun, _opts) do
        chunks = ["data: {\"text\":\"a\"}\n\n"]

        Enum.reduce_while(chunks, {:ok, acc}, fn chunk, {:ok, acc} ->
          case fun.({:data, chunk}, acc) do
            {:cont, acc} -> {:cont, {:ok, acc}}
            {:halt, acc} -> {:halt, {:ok, acc}}
          end
        end)
      end
    end

    defmodule NoStatusProvider do
      @moduledoc false
      use LlmCall.Provider,
        base_url: "https://x.test",
        auth: :none,
        http: LlmCall.StreamTest.NoStatusHTTP,
        codecs: [chat: LlmCall.StreamTest.StreamingCodec]
    end

    {:ok, stream} = LlmCall.stream(NoStatusProvider.client(), request())

    assert [%StreamEvent{type: :text_delta}, %StreamEvent{type: :message_stop}] =
             Enum.to_list(stream)
  end

  test "yields events in order and finishes the stream" do
    FakeHTTP.put_events([
      {:status, 200},
      {:data, sse(~s({"text":"Hel"}))},
      {:data, sse(~s({"text":"lo"}))},
      {:data, sse(~s("DONE"))}
    ])

    assert {:ok, stream} = LlmCall.stream(client(), request())

    events = Enum.to_list(stream)

    assert Enum.map(events, & &1.type) == [:text_delta, :text_delta, :message_stop]

    assert Enum.map(Enum.filter(events, &(&1.type == :text_delta)), & &1.delta.text) == [
             "Hel",
             "lo"
           ]
  end

  test "an invalid request is a tagged error before any request is made" do
    FakeHTTP.put_events([])

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.stream(client(), request(), codec: :vision)

    assert message =~ ":vision"
    assert FakeHTTP.requests() == []
  end

  test "stream: false is overridden, because the function is the intent" do
    FakeHTTP.put_events([{:status, 200}, {:data, sse(~s("DONE"))}])

    assert {:ok, stream} = LlmCall.stream(client(), %{request() | stream: false})

    assert {:done, :ok} =
             LlmCall.Stream.reduce(stream, :ok, fn _event, acc -> {:cont, acc} end)
  end

  test "a 401 raises with the decoded provider error and status" do
    FakeHTTP.put_events([
      {:status, 401},
      {:data, ~s({"error":{"message":"bad key"}})}
    ])

    assert {:ok, stream} = LlmCall.stream(client(), request())

    exception =
      assert_raise HTTP.Error, fn -> Enum.to_list(stream) end

    assert %Error{kind: :provider, message: "bad key", status: 401} = HTTP.Error.error(exception)
  end

  test "an unparseable payload raises :invalid_response" do
    FakeHTTP.put_events([{:status, 200}, {:data, "data: not json\n\n"}])

    assert {:ok, stream} = LlmCall.stream(client(), request())

    exception = assert_raise HTTP.Error, fn -> Enum.to_list(stream) end
    assert %Error{kind: :invalid_response} = HTTP.Error.error(exception)
  end

  test "halting stops the request and skips finish_stream" do
    FakeHTTP.put_events([
      {:status, 200},
      {:data, sse(~s({"text":"one"}))},
      {:data, sse(~s({"text":"two"}))}
    ])

    assert {:ok, stream} = LlmCall.stream(client(), request())

    assert {:halted, events} =
             LlmCall.Stream.reduce(stream, [], fn event, acc -> {:halt, [event | acc]} end)

    assert [%StreamEvent{type: :text_delta}] = events
  end

  test "a trailing event without a blank line is flushed" do
    FakeHTTP.put_events([{:status, 200}, {:data, ~s(data: {"text":"tail"})}])

    assert {:ok, stream} = LlmCall.stream(client(), request())

    assert [
             %StreamEvent{type: :text_delta, delta: %{text: "tail"}},
             %StreamEvent{type: :message_stop}
           ] =
             Enum.to_list(stream)
  end
end
