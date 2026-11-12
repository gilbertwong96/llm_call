defmodule LlmCall.TestCodec.Fake do
  @moduledoc false
  @behaviour LlmCall.Codec

  alias LlmCall.{
    Capabilities,
    Codec,
    EncodedRequest,
    Error,
    Request,
    Response,
    StreamEvent,
    StreamState
  }

  alias LlmCall.StreamDelta

  @impl true
  def info, do: %Codec.Info{name: :fake, protocol: :fake, version: "1", ir_version: 1}

  @impl true
  def validate_request(%Request{model: model}, _config) when is_binary(model) and model != "",
    do: :ok

  def validate_request(_request, _config),
    do: {:error, %Error{kind: :validation, message: "fake: model is required"}}

  @impl true
  def encode_request(request, config) do
    with :ok <- validate_request(request, config) do
      {:ok, %EncodedRequest{path: "/fake", body: %{"model" => request.model}}}
    end
  end

  @impl true
  def decode_response(%{"text" => text}, config) do
    {:ok,
     %Response{
       content: [%LlmCall.Content.Text{text: text}],
       raw: if(config.capture_raw == :none, do: nil, else: %{"text" => text})
     }}
  end

  def decode_response(term, _config) do
    {:error,
     %Error{kind: :invalid_response, message: "fake: bad payload", raw: %{"payload" => term}}}
  end

  @impl true
  def decode_error(%{"error" => %{"message" => message}} = payload, _config) do
    %Error{kind: :provider, message: message, raw: payload}
  end

  def decode_error(_term, _config),
    do: %Error{kind: :invalid_response, message: "fake: bad error payload"}

  @impl true
  def capabilities(_request, _config),
    do: %Capabilities{tools: true, streaming: true, stateful: false}

  @impl true
  def init_stream(_request, _config), do: {:ok, StreamState.new(__MODULE__, %{seen: 0})}

  @impl true
  def decode_stream_event(%{"delta" => text}, config, state) do
    data = StreamState.data(state)

    event = %StreamEvent{
      type: :text_delta,
      delta: %StreamDelta.Text{text: text},
      raw: if(config.capture_raw == :all, do: %{"delta" => text}, else: nil)
    }

    {:ok, [event], StreamState.new(__MODULE__, %{data | seen: data.seen + 1})}
  end

  def decode_stream_event("[DONE]", _config, state), do: {:done, state}
  def decode_stream_event(_term, _config, state), do: {:ok, [], state}

  @impl true
  def finish_stream(state, _config), do: {:ok, [%StreamEvent{type: :message_stop}], state}
end
