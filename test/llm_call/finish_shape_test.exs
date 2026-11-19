defmodule LlmCall.FinishShapeTest do
  use ExUnit.Case, async: true

  alias LlmCall.{
    Capabilities,
    Content,
    EncodedRequest,
    Error,
    Message,
    Request,
    StreamState
  }

  alias LlmCall.TestHTTPServer, as: TestHTTP

  defmodule BaseCodec do
    @moduledoc false

    def validate_request(_request, _config), do: :ok

    def encode_request(_request, _config),
      do: {:ok, %EncodedRequest{method: :post, path: "/stream", body: %{"stream" => true}}}

    def decode_response(_term, _config),
      do: {:error, %Error{kind: :invalid_response, message: "bad"}}

    def decode_error(_term, _config), do: %Error{kind: :provider, message: "bad"}

    def capabilities(_request, _config), do: %Capabilities{streaming: true}

    def init_stream(_request, _config), do: {:ok, StreamState.new(__MODULE__, %{})}
  end

  defmodule BadFinishCodec do
    @moduledoc false

    defdelegate validate_request(request, config), to: BaseCodec
    defdelegate encode_request(request, config), to: BaseCodec
    defdelegate decode_response(term, config), to: BaseCodec
    defdelegate decode_error(term, config), to: BaseCodec
    defdelegate capabilities(request, config), to: BaseCodec
    defdelegate init_stream(request, config), to: BaseCodec

    def decode_stream_event(_term, _config, state), do: {:ok, [], state}
    def finish_stream(state, _config), do: {:done, state}
  end

  defmodule BadDecodeCodec do
    @moduledoc false

    defdelegate validate_request(request, config), to: BaseCodec
    defdelegate encode_request(request, config), to: BaseCodec
    defdelegate decode_response(term, config), to: BaseCodec
    defdelegate decode_error(term, config), to: BaseCodec
    defdelegate capabilities(request, config), to: BaseCodec
    defdelegate init_stream(request, config), to: BaseCodec

    def decode_stream_event(_term, _config, _state), do: :not_a_tuple
    def finish_stream(state, _config), do: {:ok, [], state}
  end

  defmodule BadFinishProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :none,
      codecs: [chat: BadFinishCodec]
  end

  defmodule BadDecodeProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :none,
      codecs: [chat: BadDecodeCodec]
  end

  setup do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    :ok
  end

  defp request do
    %Request{model: "m", messages: [%Message{role: :user, content: [%Content.Text{text: "x"}]}]}
  end

  test "a finish_stream that returns an unsupported shape raises HTTP.Error" do
    TestHTTP.put_events([{:status, 200}])
    client = BadFinishProvider.client(base_url: TestHTTP.url())
    assert {:ok, stream} = LlmCall.stream(client, request())

    exception = assert_raise LlmCall.HTTP.Error, fn -> Enum.to_list(stream) end
    assert %Error{kind: :invalid_response} = LlmCall.HTTP.Error.error(exception)
  end

  test "a decode_stream_event that returns an unsupported shape raises HTTP.Error" do
    TestHTTP.put_events([{:status, 200}, {:data, "data: {}\n\n"}])
    client = BadDecodeProvider.client(base_url: TestHTTP.url())
    assert {:ok, stream} = LlmCall.stream(client, request())

    exception = assert_raise LlmCall.HTTP.Error, fn -> Enum.to_list(stream) end
    assert %Error{kind: :invalid_response} = LlmCall.HTTP.Error.error(exception)
  end
end
