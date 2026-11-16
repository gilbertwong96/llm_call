defmodule LlmDialect.Protocol.Adapter do
  @moduledoc """
  `use` for a completion adapter.

  Injects the behaviour, the canonical aliases every completion codec needs, and
  the codec's own name:

      use LlmDialect.Protocol.Adapter, codec: :openai_chat
  """

  defmacro __using__(opts) do
    codec = Keyword.fetch!(opts, :codec)
    encode? = Keyword.get(opts, :encode, true)

    quote do
      @behaviour LlmDialect.Codec

      alias LlmDialect.{
        Capabilities,
        Codec,
        Config,
        Content,
        EncodedRequest,
        Error,
        Message,
        Reasoning,
        ReasoningCapabilities,
        Request,
        Response,
        StreamState,
        ToolCall,
        ToolResult,
        ToolSpec,
        Usage
      }

      alias LlmDialect.Protocol.Helpers
      alias LlmDialect.StreamDelta

      @codec unquote(codec)

      if unquote(encode?) do
        @impl true
        def encode_request(%Request{} = request, %Config{} = config) do
          Helpers.encode_completion(
            request,
            config,
            @path,
            @headers,
            &validate_request/2,
            &body/2
          )
        end
      end
    end
  end
end
