defmodule LlmCall.Dialect.Bedrock.Converse do
  @moduledoc """
  Bedrock's `Converse` API (`POST /model/{modelId}/converse`).

  One request shape covers every model Bedrock serves, which is why it is the
  dialect worth implementing first: `anthropic_version` and each vendor's own
  envelope disappear behind `messages`, `system` and `inferenceConfig`.

  A model ID is **one** path segment. Bedrock IDs carry `:` and inference-profile
  ARNs carry `/`, so the ID is percent-encoded here and signed verbatim by the
  transport.

  This phase carries text, tool use, and inline images and documents. A part whose
  bytes travel with the request is encoded (`source.bytes`); a part that names a
  provider-owned location is refused, because the canonical IR has no source for one
  — Converse can point at S3, and nothing here can say so without inventing a
  convention every other codec would have to learn. `capabilities/2` reports exactly
  that: `image_input` and `file_input` accept `:inline` and nothing else.

  ## Native options

  `provider_options.bedrock` is merged into the **top level** of the Converse
  request, the rule the OpenAI, Anthropic and Gemini codecs already follow. That
  is what makes `guardrailConfig`, `performanceConfig`, `requestMetadata` and
  `promptVariables` reachable, and `additionalModelRequestFields` is one more
  top-level field rather than a special case:

      provider_options: %{bedrock: %{"additionalModelRequestFields" => %{"top_k" => 200}}}

  The canonical envelope keys — `messages`, `system`, `inferenceConfig`,
  `toolConfig` — are reserved: an option that would replace one is a
  `:validation` error, never a silent override.

  ## Streaming

  `ConverseStream` is a second endpoint, not a flag in the body, so
  `encode_request/2` picks `/converse-stream` from `Request.stream`. Its body is a
  single binary frame stream rather than SSE, declared through `stream_framing/0`.

  Bedrock sends usage **after** `messageStop`, so this codec cannot emit the IR
  terminator there: `:message_stop` would be followed by another event. The stop
  reason arrives at `messageStop`, the usage at `metadata`, and `finish_stream/2`
  emits `:message_stop` when the body ends — the same shape Gemini uses, and the same
  rule: a stream that ends without `messageStop` is an `:invalid_response`, not a
  quietly truncated one.
  """

  alias LlmCall.Dialect.Helpers

  alias LlmCall.{
    Capabilities,
    Codec,
    Config,
    Content,
    EncodedRequest,
    Error,
    Message,
    Request,
    Response,
    StreamDelta,
    StreamEvent,
    StreamState,
    ToolCall,
    ToolResult,
    ToolSpec,
    Usage
  }

  @behaviour LlmCall.Codec

  @codec :bedrock_converse
  @version "2023-09-30"
  @param_keys [:max_tokens, :temperature, :top_p, :stop]
  @tool_name_pattern ~r/\A[a-zA-Z0-9_-]+\z/
  @tool_name_max 64

  @param_spec %{
    temperature: {:number, 0, 1},
    top_p: {:number, 0, 1},
    max_tokens: {:integer, 1, :infinity},
    stop: {:stop, :infinity}
  }

  @namespaces [:bedrock]

  @image_formats %{
    "image/png" => "png",
    "image/jpeg" => "jpeg",
    "image/gif" => "gif",
    "image/webp" => "webp"
  }

  @document_formats %{
    "application/pdf" => "pdf",
    "text/csv" => "csv",
    "application/msword" => "doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
    "application/vnd.ms-excel" => "xls",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
    "text/html" => "html",
    "text/plain" => "txt",
    "text/markdown" => "md"
  }

  @envelope_keys ~w(messages system inferenceconfig toolconfig)

  @native_options %{
    "guardrailConfig" => :map,
    "performanceConfig" => :map,
    "requestMetadata" => :map,
    "promptVariables" => :map,
    "additionalModelRequestFields" => :map,
    "additionalModelResponseFieldPaths" => :list
  }

  @impl true
  def info do
    %Codec.Info{name: @codec, protocol: :bedrock_converse, version: @version, ir_version: 1}
  end

  @impl true
  def validate_request(%Request{} = request, %Config{} = config) do
    with :ok <- validate_model(request.model),
         :ok <- validate_unsupported(request),
         :ok <- validate_system(request.system),
         :ok <- validate_messages(request.messages),
         :ok <- validate_parts(request.messages),
         :ok <- validate_tools(request.tools, request.tool_choice),
         :ok <- validate_provider_options(request, config) do
      Helpers.validate_params_with_spec(request.params, @param_keys, @param_spec, @codec)
    end
  end

  @impl true
  def encode_request(%Request{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      {:ok,
       %EncodedRequest{
         method: :post,
         path: converse_path(request),
         headers: [{"content-type", "application/json"}],
         body: body(request, config)
       }}
    end
  end

  # `ConverseStream` is its own endpoint, so the flag is in the path and never in the
  # body: a body `stream: true` would be rejected by the sync endpoint.
  defp converse_path(%Request{model: model, stream: true}),
    do: "/model/" <> encode_model(model) <> "/converse-stream"

  defp converse_path(%Request{model: model}),
    do: "/model/" <> encode_model(model) <> "/converse"

  @impl true
  def stream_framing, do: LlmCall.EventStream

  @impl true
  def capabilities(%Request{}, _config) do
    %Capabilities{
      tools: true,
      tool_choice: true,
      structured_output: :none,
      modalities: [:text],
      image_input: %LlmCall.Capabilities.Input{inline: true},
      file_input: %LlmCall.Capabilities.Input{inline: true},
      streaming: true,
      stateful: false
    }
  end

  defp validate_model(model) when is_binary(model) and model != "", do: :ok
  defp validate_model(_model), do: Helpers.error(@codec, "model is required")

  @impl true
  def decode_response(
        %{"output" => %{"message" => %{"content" => content}}} = payload,
        %Config{} = config
      )
      when is_list(content) do
    {:ok,
     %Response{
       content: Enum.flat_map(content, &decode_part/1),
       stop_reason: stop_reason(payload["stopReason"]),
       usage: decode_usage(payload["usage"]),
       raw: Helpers.capture_response(config, payload)
     }}
  end

  def decode_response(_payload, _config) do
    {:error,
     %Error{kind: :invalid_response, message: "#{@codec}: payload is not a Converse response"}}
  end

  @impl true
  def decode_error(%{"message" => message} = payload, %Config{} = config)
      when is_binary(message) do
    %Error{kind: :provider, message: message, raw: Helpers.capture_response(config, payload)}
  end

  def decode_error(payload, %Config{} = config) do
    Helpers.decode_provider_error(payload, config, @codec, [], [])
  end

  @impl true
  def init_stream(%Request{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      {:ok,
       StreamState.new(__MODULE__, %{
         blocks: %{},
         usage: nil,
         stop_reason: nil,
         finished?: false
       })}
    end
  end

  # The framing hands over the whole message, headers included: `:message-type` decides
  # between an event and an exception, and `:event-type` names the event.
  @impl true
  def decode_stream_event(
        %LlmCall.EventStream.Message{headers: headers, payload: payload},
        %Config{} = config,
        %StreamState{} = state
      ) do
    with {:ok, term} <- decode_stream_payload(payload, config) do
      if headers[":message-type"] == "exception" do
        {:error, decode_error(term, config)}
      else
        data = StreamState.data(state)
        {events, data} = stream_events(headers[":event-type"], term, config, data)
        {:ok, events, StreamState.new(__MODULE__, data)}
      end
    end
  end

  def decode_stream_event(_other, _config, %StreamState{}),
    do: {:error, invalid_response("a stream event must be a framed message")}

  # `messageStop` is the terminator in Bedrock's own vocabulary, but usage arrives after
  # it, so the IR's `:message_stop` is flushed when the body ends. A stream that never
  # reaches `messageStop` was cut short and says so, rather than looking complete.
  @impl true
  def finish_stream(%StreamState{} = state, _config) do
    if StreamState.data(state).finished? do
      {:ok, [%StreamEvent{type: :message_stop}], state}
    else
      {:error, invalid_response("stream ended without messageStop")}
    end
  end

  defp decode_stream_payload(payload, %Config{} = config) do
    case LlmCall.JSON.decode(config.json, payload) do
      {:ok, %{} = term} -> {:ok, term}
      {:ok, _other} -> {:error, invalid_response("a stream event payload is not an object")}
      {:error, _reason} -> {:error, invalid_response("a stream event payload is not JSON")}
    end
  end

  defp stream_events("messageStart", term, config, data) do
    {[Helpers.event(:message_start, nil, nil, term, config)], data}
  end

  defp stream_events("contentBlockStart", term, config, data) do
    index = Helpers.index(term["contentBlockIndex"])

    case term["start"] do
      %{"toolUse" => %{"toolUseId" => id, "name" => name}} ->
        delta = %StreamDelta.ToolCall{id: id, name: name, index: index}

        {[Helpers.event(:tool_call_start, index, delta, term, config)],
         put_block(data, index, :tool_use)}

      _text_or_unknown ->
        {[Helpers.event(:content_start, index, nil, term, config)], put_block(data, index, :text)}
    end
  end

  defp stream_events("contentBlockDelta", term, config, data) do
    block_delta(term["delta"], Helpers.index(term["contentBlockIndex"]), term, config, data)
  end

  defp stream_events("contentBlockStop", term, config, data) do
    index = Helpers.index(term["contentBlockIndex"])

    case Map.get(data.blocks, index) do
      :tool_use ->
        {[
           Helpers.event(
             :tool_call_stop,
             index,
             %StreamDelta.ToolCall{index: index},
             term,
             config
           )
         ], data}

      _other ->
        {[Helpers.event(:content_stop, index, nil, term, config)], data}
    end
  end

  defp stream_events("messageStop", term, config, data) do
    data = %{data | stop_reason: stop_reason(term["stopReason"]), finished?: true}
    {[message_delta(term, config, data)], data}
  end

  defp stream_events("metadata", term, config, data) do
    data = %{data | usage: decode_usage(term["usage"]) || data.usage}

    if data.usage,
      do: {[message_delta(term, config, data)], data},
      else: {[], data}
  end

  # A provider field this codec does not map yet is kept, not dropped.
  defp stream_events(_other, term, config, data) do
    {[Helpers.event(:message_delta, nil, %StreamDelta.Raw{data: term}, term, config)], data}
  end

  defp block_delta(%{"text" => text}, index, term, config, data) when is_binary(text) do
    {[Helpers.event(:text_delta, index, %StreamDelta.Text{text: text}, term, config)], data}
  end

  defp block_delta(%{"toolUse" => %{"input" => fragment}}, index, term, config, data)
       when is_binary(fragment) do
    delta = %StreamDelta.ToolCall{arguments: fragment, index: index}
    {[Helpers.event(:tool_call_delta, index, delta, term, config)], data}
  end

  defp block_delta(%{"reasoningContent" => reasoning}, index, term, config, data)
       when is_map(reasoning) do
    thinking = %StreamDelta.Thinking{
      text: reasoning["text"] || "",
      signature: reasoning["signature"]
    }

    {[Helpers.event(:thinking_delta, index, thinking, term, config)], data}
  end

  defp block_delta(delta, _index, term, config, data) do
    raw = %StreamDelta.Raw{data: delta || %{}}
    {[Helpers.event(:message_delta, nil, raw, term, config)], data}
  end

  # The stop reason is known before the usage is, so a delta after `metadata` carries
  # both: a caller that reads the last delta has the whole picture.
  defp message_delta(term, config, data) do
    delta = %StreamDelta.MessageDelta{stop_reason: data.stop_reason, usage: data.usage}
    Helpers.event(:message_delta, nil, delta, term, config)
  end

  defp put_block(data, index, type), do: %{data | blocks: Map.put(data.blocks, index, type)}

  defp invalid_response(message),
    do: %Error{kind: :invalid_response, message: "#{@codec}: " <> message}

  defp decode_part(%{"text" => text}) when is_binary(text), do: [%Content.Text{text: text}]

  defp decode_part(%{"toolUse" => %{"toolUseId" => id, "name" => name} = tool}) do
    [%ToolCall{id: id, name: name, arguments: tool["input"] || %{}}]
  end

  defp decode_part(part) when is_map(part) do
    [%Content.Raw{type: part |> Map.keys() |> Enum.sort() |> List.first(), data: part}]
  end

  defp decode_part(_part), do: []

  defp stop_reason("end_turn"), do: :end_turn
  defp stop_reason("tool_use"), do: :tool_calls
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason("stop_sequence"), do: :stop_sequence
  defp stop_reason("content_filtered"), do: :content_filter
  defp stop_reason("guardrail_intervened"), do: :content_filter
  defp stop_reason("model_context_window_exceeded"), do: :max_tokens
  defp stop_reason("malformed_model_output"), do: :error
  defp stop_reason("malformed_tool_use"), do: :error
  defp stop_reason(_reason), do: :unknown

  defp decode_usage(%{} = usage) do
    %Usage{
      input_tokens: Helpers.token(usage["inputTokens"]),
      output_tokens: Helpers.token(usage["outputTokens"]),
      total_tokens: Helpers.token(usage["totalTokens"]),
      cache_read_tokens: Helpers.token(usage["cacheReadInputTokens"]),
      cache_write_tokens: Helpers.token(usage["cacheWriteInputTokens"])
    }
  end

  defp decode_usage(_usage), do: nil

  defp validate_unsupported(%Request{reasoning: reasoning}) when not is_nil(reasoning),
    do: Helpers.error(@codec, "reasoning is not supported by Converse")

  defp validate_unsupported(%Request{output: output}) when output != :text,
    do: Helpers.error(@codec, "output #{inspect(output)} is not supported by Converse")

  defp validate_unsupported(%Request{modalities: modalities}) when modalities != [:text],
    do: Helpers.error(@codec, "modalities #{inspect(modalities)} are not supported by Converse")

  defp validate_unsupported(_request), do: :ok

  defp validate_system(system), do: Helpers.validate_system(system, @codec)

  defp validate_messages([]),
    do: Helpers.error(@codec, "messages must contain at least one message")

  defp validate_messages(messages) when is_list(messages) do
    Helpers.first_error(messages, fn
      %Message{content: []} -> Helpers.error(@codec, "a message needs at least one content part")
      %Message{} -> :ok
    end)
  end

  defp validate_messages(_messages), do: Helpers.error(@codec, "messages must be a list")

  defp validate_parts(messages), do: Helpers.validate_parts(messages, @codec, &validate_part/2)

  defp validate_part(_role, %Content.Text{}), do: :ok
  defp validate_part(_role, %ToolCall{id: id}) when is_binary(id) and id != "", do: :ok
  defp validate_part(_role, %ToolCall{}), do: Helpers.error(@codec, "tool calls require an id")

  defp validate_part(_role, %ToolResult{call_id: id}) when not is_binary(id) or id == "",
    do: Helpers.error(@codec, "tool results require a call_id")

  defp validate_part(_role, %ToolResult{content: content}) when content in [nil, "", []],
    do: Helpers.error(@codec, "tool results require content")

  defp validate_part(_role, %ToolResult{}), do: :ok

  # Converse carries the bytes itself (`source.bytes`) or points at S3. The canonical
  # IR has no provider-owned-URI source, so only inline is reachable; saying so here
  # is better than letting a caller assemble a part the API would reject.
  defp validate_part(_role, %Content.Image{source: {:base64, data}, media_type: media_type})
       when is_binary(data) do
    case Map.fetch(@image_formats, media_type) do
      {:ok, _format} -> :ok
      :error -> Helpers.error(@codec, image_format_message(media_type))
    end
  end

  defp validate_part(_role, %Content.Image{source: source}),
    do: Helpers.error(@codec, inline_only("Image", source))

  defp validate_part(_role, %Content.File{source: {:base64, data}} = file) when is_binary(data) do
    with :ok <- validate_document_name(file),
         {:ok, _format} <- Map.fetch(@document_formats, file.media_type) do
      :ok
    else
      :error -> Helpers.error(@codec, document_format_message(file.media_type))
      error -> error
    end
  end

  defp validate_part(_role, %Content.File{source: source}),
    do: Helpers.error(@codec, inline_only("File", source))

  defp validate_part(_role, %Content.Video{}),
    do: Helpers.error(@codec, "Content.Video parts are not supported")

  defp validate_part(_role, %Content.Thinking{}),
    do: Helpers.error(@codec, "Content.Thinking parts are not supported")

  defp validate_part(_role, %Content.Raw{}),
    do: Helpers.error(@codec, "Content.Raw parts are not supported")

  defp validate_part(_role, _part), do: Helpers.error(@codec, "unsupported content part")

  defp validate_document_name(%Content.File{filename: name}) when is_binary(name) and name != "",
    do: :ok

  defp validate_document_name(_file),
    do: Helpers.error(@codec, "Content.File needs filename, which Converse sends as name")

  defp image_format_message(media_type) do
    "Content.Image media_type #{inspect(media_type)} is not one Converse accepts " <>
      "(#{accepted(@image_formats)})"
  end

  defp document_format_message(media_type) do
    "Content.File media_type #{inspect(media_type)} is not one Converse accepts " <>
      "(#{accepted(@document_formats)})"
  end

  defp inline_only(part, source) do
    "Content.#{part} source #{inspect(source)} is not supported; " <>
      "Converse takes the bytes inline (media_type plus {:base64, data})"
  end

  defp accepted(formats), do: formats |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp validate_provider_options(%Request{} = request, %Config{} = config) do
    request_options = Map.get(request.provider_options, :bedrock, %{})
    default_options = Map.get(config.default_provider_options, :bedrock, %{})

    with :ok <-
           Helpers.validate_option_map(
             request.provider_options,
             @codec,
             "provider_options",
             @namespaces
           ),
         # A default map is application-wide and legitimately carries namespaces for
         # other providers, so only the one this codec reads is checked.
         :ok <-
           Helpers.validate_option_map(
             config.default_provider_options,
             @codec,
             "default_provider_options",
             @namespaces,
             strict?: false
           ),
         :ok <- validate_native_options(request_options, "provider_options") do
      validate_native_options(default_options, "default_provider_options")
    end
  end

  # A native option may add a Converse field or override one the codec does not
  # produce, but it may not replace the envelope the canonical IR owns.
  defp validate_native_options(options, label) when is_map(options) do
    with :ok <- Helpers.validate_option_keys(options, @envelope_keys, @codec) do
      Helpers.validate_native_options(options, @native_options, @codec, label)
    end
  end

  defp validate_native_options(_options, label),
    do: Helpers.error(@codec, "#{label} must be a map")

  defp validate_tools(tools, tool_choice) do
    Helpers.validate_tools(
      tools,
      tool_choice,
      @codec,
      &validate_tool_spec/1,
      &validate_tool_choice/2
    )
  end

  defp validate_tool_spec(%ToolSpec{} = spec) do
    with :ok <- validate_tool_parameters(spec.parameters) do
      Helpers.validate_tool_spec(spec, @codec,
        builtin_tools: false,
        name_pattern: {@tool_name_pattern, @tool_name_max, "Converse"}
      )
    end
  end

  defp validate_tool_parameters(parameters) when is_map(parameters), do: :ok

  defp validate_tool_parameters(_parameters),
    do: Helpers.error(@codec, "tool parameters must be a JSON schema object")

  defp validate_tool_choice(choice, tools) do
    with :ok <- Helpers.validate_tool_choice(choice, tools, @codec) do
      case {choice, tools} do
        {:none, [_tool | _rest]} ->
          Helpers.error(@codec, "tool_choice :none cannot be expressed while tools are declared")

        _other ->
          :ok
      end
    end
  end

  defp encode_model(model), do: URI.encode(model, &URI.char_unreserved?/1)

  defp body(%Request{} = request, %Config{} = config) do
    %{"messages" => messages(request.messages, config)}
    |> Helpers.maybe_put("system", system(request.system))
    |> Helpers.maybe_put("inferenceConfig", inference_config(request.params))
    |> Helpers.maybe_put("toolConfig", tool_config(request.tools, request.tool_choice))
    |> Config.deep_merge(provider_options(request, config))
  end

  defp provider_options(%Request{} = request, %Config{} = config) do
    request
    |> Config.provider_options(config)
    |> Map.get(:bedrock, %{})
  end

  defp messages(messages, config) do
    messages
    |> Enum.map(&message(&1, config))
    |> merge_tool_results()
  end

  defp merge_tool_results(encoded) do
    encoded
    |> Enum.reduce([], fn
      %{"role" => "user", "content" => current} = message,
      [%{"role" => "user", "content" => previous} = merged | rest] ->
        if tool_results?(previous) and tool_results?(current),
          do: [%{merged | "content" => previous ++ current} | rest],
          else: [message, merged | rest]

      message, acc ->
        [message | acc]
    end)
    |> Enum.reverse()
  end

  defp tool_results?(blocks) do
    blocks != [] and Enum.all?(blocks, fn block -> Map.has_key?(block, "toolResult") end)
  end

  defp message(%Message{role: role, content: content}, config) do
    %{"role" => role_name(role), "content" => Enum.map(content, &part(&1, config))}
  end

  defp role_name(:assistant), do: "assistant"
  defp role_name(_role), do: "user"

  defp part(%Content.Text{text: text}, _config), do: %{"text" => text}

  defp part(%Content.Image{source: {:base64, data}, media_type: media_type}, _config) do
    %{
      "image" => %{
        "format" => Map.fetch!(@image_formats, media_type),
        "source" => %{"bytes" => data}
      }
    }
  end

  defp part(%Content.File{source: {:base64, data}} = file, _config) do
    %{
      "document" => %{
        "format" => Map.fetch!(@document_formats, file.media_type),
        "name" => file.filename,
        "source" => %{"bytes" => data}
      }
    }
  end

  defp part(%ToolCall{id: id, name: name, arguments: arguments, raw_arguments: raw}, config) do
    input = arguments || Helpers.decode_raw_arguments(raw, config.json) || %{}

    %{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => input}}
  end

  defp part(%ToolResult{call_id: call_id, content: content, is_error: is_error}, _config) do
    %{
      "toolResult" => %{
        "toolUseId" => call_id,
        "content" => tool_result_content(content),
        "status" => if(is_error, do: "error", else: "success")
      }
    }
  end

  defp tool_result_content(content) when is_binary(content), do: [%{"text" => content}]

  defp tool_result_content(content) when is_list(content) do
    Enum.map(content, fn %Content.Text{text: text} -> %{"text" => text} end)
  end

  defp system(nil), do: nil
  defp system([]), do: nil
  defp system(text) when is_binary(text), do: [%{"text" => text}]

  defp system(parts) when is_list(parts),
    do: Enum.map(parts, fn %Content.Text{text: t} -> %{"text" => t} end)

  defp inference_config(params) do
    %{}
    |> Helpers.maybe_put("maxTokens", Map.get(params, :max_tokens))
    |> Helpers.maybe_put("temperature", Map.get(params, :temperature))
    |> Helpers.maybe_put("topP", Map.get(params, :top_p))
    |> Helpers.maybe_put("stopSequences", stop_sequences(Map.get(params, :stop)))
    |> absent_if_empty()
  end

  defp stop_sequences(nil), do: nil
  defp stop_sequences(stop) when is_binary(stop), do: [stop]
  defp stop_sequences(stop) when is_list(stop), do: stop

  defp tool_config([], _tool_choice), do: nil

  defp tool_config(tools, tool_choice) do
    %{"tools" => Enum.map(tools, &tool/1)}
    |> Helpers.maybe_put("toolChoice", tool_choice_wire(tool_choice))
  end

  defp tool(%ToolSpec{} = spec) do
    %{
      "toolSpec" =>
        %{
          "name" => spec.name,
          "inputSchema" => %{"json" => spec.parameters}
        }
        |> Helpers.maybe_put("description", spec.description)
    }
  end

  defp tool_choice_wire(:auto), do: nil
  defp tool_choice_wire(:required), do: %{"any" => %{}}
  defp tool_choice_wire({:tool, name}), do: %{"tool" => %{"name" => name}}

  defp absent_if_empty(map) when is_map(map) and map_size(map) == 0, do: nil
  defp absent_if_empty(value), do: value
end
