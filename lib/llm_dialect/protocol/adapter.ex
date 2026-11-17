defmodule LlmDialect.Protocol.Adapter do
  @moduledoc """
  `use` for a completion adapter.

  Injects the behaviour, the canonical aliases, the codec's own name, and
  `encode_request/2`:

      use LlmDialect.Protocol.Adapter, codec: :openai_chat

      @path "/v1/chat/completions"
      @headers [{"content-type", "application/json"}]

  `@path` and `@headers` may appear anywhere in the module body; they are read
  once the module finishes, so declaration order does not matter.

  The codec still supplies `info/0`, `capabilities/2`, `validate_request/2`, and
  a private `body/2` that returns the wire body for a validated request.

  Pass `encode: false` when the protocol needs its own `encode_request/2` — for
  example a per-model path or a non-`POST` method.
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
      @llm_dialect_encode unquote(encode?)

      @before_compile LlmDialect.Protocol.Adapter
    end
  end

  defmacro __before_compile__(env) do
    if Module.get_attribute(env.module, :llm_dialect_encode) do
      if Module.defines?(env.module, {:encode_request, 2}) or
           Module.defines?(env.module, {:encode_request, 2}, :defp) do
        raise ArgumentError,
              "#{inspect(env.module)} defines encode_request/2 and also uses " <>
                "LlmDialect.Protocol.Adapter with encode: true; pass encode: false"
      end

      path = Module.get_attribute(env.module, :path)
      headers = Module.get_attribute(env.module, :headers)

      unless is_binary(path) and is_list(headers) do
        raise ArgumentError,
              "#{inspect(env.module)} must set @path (a string) and @headers (a list) " <>
                "when using LlmDialect.Protocol.Adapter"
      end

      quote do
        @doc """
        Validates the request and encodes it as a `POST` to the codec's `@path`.
        """
        @impl true
        @spec encode_request(LlmDialect.Request.t(), LlmDialect.Config.t()) ::
                {:ok, LlmDialect.EncodedRequest.t()} | {:error, LlmDialect.Error.t()}
        def encode_request(
              %LlmDialect.Request{} = request,
              %LlmDialect.Config{} = config
            ) do
          LlmDialect.Protocol.Helpers.encode_completion(
            request,
            config,
            unquote(path),
            unquote(headers),
            &validate_request/2,
            &body/2
          )
        end
      end
    end
  end
end
