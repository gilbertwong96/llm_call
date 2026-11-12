defmodule LlmCall.Protocol.Gemini.GenerateContent do
  @moduledoc """
  Gemini `generateContent` / `streamGenerateContent` (`v1beta`).

  Messages become `contents`, where an assistant turn is `role: "model"`. System
  instructions are a top-level `systemInstruction`, sampling and output controls
  live in `generationConfig`, and reasoning maps to `thinkingConfig`.

  Gemini identifies a tool result by function `name`, not by a call id, so
  `LlmCall.ToolResult.call_id` is not represented on this protocol. A request
  without a function `name` on the result is rejected.

  Streaming changes the method in the path (`:streamGenerateContent`) and adds
  `alt=sse` to the query; the transport still owns SSE framing.
  """

  alias LlmCall.{
    Capabilities,
    Config,
    Content,
    EncodedRequest,
    Error,
    Message,
    Reasoning,
    ReasoningCapabilities,
    Request,
    Response,
    StreamEvent,
    StreamState,
    ToolCall,
    ToolResult,
    ToolSpec,
    Usage
  }

  alias LlmCall.StreamDelta

  @behaviour LlmCall.Codec

  @api_version "v1beta"
  @headers [{"content-type", "application/json"}]
  @reserved_keys ~w(model messages system contents tools stream)
  @param_keys [:temperature, :top_p, :top_k, :max_tokens, :stop]
  @efforts [nil, :none, :low, :high]
  @retryable_statuses ~w(RESOURCE_EXHAUSTED UNAVAILABLE INTERNAL DEADLINE_EXCEEDED)

  @impl true
  @spec info() :: LlmCall.Codec.Info.t()
  def info do
    %LlmCall.Codec.Info{
      name: :gemini_generate_content,
      protocol: :gemini_generate_content,
      version: @api_version,
      ir_version: 1
    }
  end

  @impl true
  @spec encode_request(Request.t(), Config.t()) ::
          {:ok, EncodedRequest.t()} | {:error, Error.t()}
  def encode_request(%Request{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      {:ok,
       %EncodedRequest{
         method: :post,
         path: path(request),
         query: query(request),
         headers: @headers,
         body: body(request, config)
       }}
    end
  end

  @impl true
  @spec validate_request(Request.t(), Config.t()) :: :ok | {:error, Error.t()}
  def validate_request(%Request{} = request, %Config{} = config) do
    with :ok <- validate_model(request.model),
         :ok <- validate_messages(request.messages),
         :ok <- validate_params(request.params),
         :ok <- validate_reasoning(request.reasoning),
         :ok <- validate_output(request.output),
         :ok <- validate_tools(request.tools, request.tool_choice),
         :ok <- validate_system(request.system),
         :ok <- validate_parts(request.messages),
         :ok <- validate_provider_options(request, config) do
      :ok
    end
  end

  defp path(%Request{model: model, stream: true}),
    do: "/v1beta/models/#{model}:streamGenerateContent"

  defp path(%Request{model: model}), do: "/v1beta/models/#{model}:generateContent"

  defp query(%Request{stream: true}), do: %{"alt" => "sse"}
  defp query(%Request{}), do: %{}

  defp body(request, config) do
    %{}
    |> Map.put("contents", Enum.map(request.messages, &encode_message/1))
    |> maybe_put("systemInstruction", encode_system(request.system))
    |> maybe_put("tools", encode_tools(request.tools))
    |> maybe_put("toolConfig", encode_tool_config(request.tool_choice, request.tools))
    |> maybe_put("generationConfig", encode_generation_config(request))
    |> Map.merge(provider_options(request, config))
  end

  defp encode_message(%Message{role: role, content: content}) do
    %{
      "role" => if(role == :assistant, do: "model", else: "user"),
      "parts" => Enum.map(content, &encode_part/1)
    }
  end

  defp encode_system(nil), do: nil

  defp encode_system(text) when is_binary(text) do
    %{"parts" => [%{"text" => text}]}
  end

  defp encode_system(parts) when is_list(parts) do
    %{"parts" => Enum.map(parts, fn %Content.Text{text: text} -> %{"text" => text} end)}
  end

  defp encode_part(%Content.Text{text: text}), do: %{"text" => text}

  defp encode_part(%Content.Thinking{text: text}), do: %{"text" => text, "thought" => true}

  defp encode_part(%Content.Image{source: {:base64, data}, media_type: media_type}) do
    %{"inlineData" => %{"mimeType" => media_type, "data" => data}}
  end

  defp encode_part(%Content.Image{source: {:url, url}, media_type: media_type}) do
    %{"fileData" => %{"fileUri" => url} |> maybe_put("mimeType", media_type)}
  end

  defp encode_part(%Content.Image{source: url}) when is_binary(url) do
    %{"fileData" => %{"fileUri" => url}}
  end

  defp encode_part(%Content.File{source: {:base64, data}, media_type: media_type}) do
    %{"inlineData" => %{"mimeType" => media_type, "data" => data}}
  end

  defp encode_part(%Content.File{source: {:url, url}, media_type: media_type}) do
    %{"fileData" => %{"fileUri" => url} |> maybe_put("mimeType", media_type)}
  end

  defp encode_part(%Content.File{source: url}) when is_binary(url) do
    %{"fileData" => %{"fileUri" => url}}
  end

  defp encode_part(%ToolCall{} = call) do
    %{
      "functionCall" => %{
        "name" => call.name,
        "args" => call.arguments || decode_raw_arguments(call) || %{}
      }
    }
  end

  defp encode_part(%ToolResult{} = result) do
    response =
      case result.is_error do
        true -> %{"error" => tool_result_text(result.content)}
        _other -> %{"result" => tool_result_text(result.content)}
      end

    %{"functionResponse" => %{"name" => result.name, "response" => response}}
  end

  defp encode_part(%Content.Raw{data: %{} = data}), do: data

  defp tool_result_text(content) when is_binary(content), do: content
  defp tool_result_text(parts) when is_list(parts), do: Enum.map_join(parts, "\n", & &1.text)

  defp decode_raw_arguments(%ToolCall{raw_arguments: raw}) when is_binary(raw) do
    case :json.decode(raw) do
      %{} = decoded -> decoded
      _not_a_map -> nil
    end
  rescue
    _decode_error -> nil
  end

  defp decode_raw_arguments(_call), do: nil

  defp encode_tools([]), do: nil

  defp encode_tools(specs) do
    declarations =
      Enum.map(specs, fn %ToolSpec{} = spec ->
        %{"name" => spec.name}
        |> maybe_put("description", spec.description)
        |> maybe_put("parameters", spec.parameters)
      end)

    [%{"functionDeclarations" => declarations}]
  end

  defp encode_tool_config(_choice, []), do: nil
  defp encode_tool_config(:auto, _tools), do: nil
  defp encode_tool_config(:none, _tools), do: %{"functionCallingConfig" => %{"mode" => "NONE"}}
  defp encode_tool_config(:required, _tools), do: %{"functionCallingConfig" => %{"mode" => "ANY"}}

  defp encode_tool_config({:tool, name}, _tools) do
    %{"functionCallingConfig" => %{"mode" => "ANY", "allowedFunctionNames" => [name]}}
  end

  defp encode_tool_config({:allowed, names}, _tools) do
    %{"functionCallingConfig" => %{"mode" => "ANY", "allowedFunctionNames" => names}}
  end

  defp encode_generation_config(request) do
    config =
      %{}
      |> maybe_put("temperature", request.params[:temperature])
      |> maybe_put("topP", request.params[:top_p])
      |> maybe_put("topK", request.params[:top_k])
      |> maybe_put("maxOutputTokens", request.params[:max_tokens])
      |> maybe_put("stopSequences", request.params[:stop])
      |> Map.merge(encode_output(request.output))
      |> maybe_put("thinkingConfig", encode_thinking(request.reasoning))

    if config == %{}, do: nil, else: config
  end

  defp encode_output(:text), do: %{}
  defp encode_output(:json_object), do: %{"responseMimeType" => "application/json"}

  defp encode_output({:json_schema, _name, schema, _strict}) do
    %{"responseMimeType" => "application/json", "responseSchema" => schema}
  end

  defp encode_thinking(nil), do: nil

  defp encode_thinking(%Reasoning{budget_tokens: budget}) when is_integer(budget),
    do: %{"thinkingBudget" => budget}

  defp encode_thinking(%Reasoning{effort: :none}), do: %{"thinkingBudget" => 0}

  defp encode_thinking(%Reasoning{effort: effort}) when effort in [:low, :high],
    do: %{"thinkingLevel" => Atom.to_string(effort)}

  defp encode_thinking(%Reasoning{}), do: nil

  defp provider_options(request, config) do
    options = Config.provider_options(request, config)
    Map.get(options, :gemini) || Map.get(options, :google) || %{}
  end

  defp validate_model(model) when is_binary(model) and model != "", do: :ok
  defp validate_model(_model), do: error("model is required")

  defp validate_messages([]), do: error("at least one message is required")

  defp validate_messages(messages) when is_list(messages) do
    first_error(messages, fn
      %Message{role: role, content: content}
      when role in [:user, :assistant] and is_list(content) ->
        :ok

      %Message{role: role} when role in [:user, :assistant] ->
        error("message content must be a list")

      %Message{} ->
        error("message role must be :user or :assistant")

      _other ->
        error("messages must be LlmCall.Message structs")
    end)
  end

  defp validate_messages(_messages), do: error("messages must be a list")

  defp validate_params(params) when is_map(params) do
    first_error(Map.keys(params), fn key ->
      if key in @param_keys, do: :ok, else: error("params key #{inspect(key)} is not supported")
    end)
  end

  defp validate_params(_params), do: error("params must be a map")

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%Reasoning{} = reasoning) do
    with :ok <- validate_effort(reasoning.effort),
         :ok <- validate_budget(reasoning.budget_tokens),
         :ok <- reject(reasoning.summary, "reasoning summary is not supported"),
         :ok <- reject_effort_with_budget(reasoning) do
      :ok
    end
  end

  defp validate_reasoning(_reasoning), do: error("reasoning must be a LlmCall.Reasoning struct")

  defp validate_effort(effort) when effort in @efforts, do: :ok
  defp validate_effort(effort), do: error("reasoning effort #{inspect(effort)} is not supported")

  defp validate_budget(nil), do: :ok
  defp validate_budget(budget) when is_integer(budget) and budget > 0, do: :ok
  defp validate_budget(_budget), do: error("reasoning budget_tokens must be a positive integer")

  defp reject_effort_with_budget(%Reasoning{budget_tokens: budget, effort: effort})
       when not is_nil(budget) and not is_nil(effort) do
    error("reasoning budget_tokens and effort cannot be combined")
  end

  defp reject_effort_with_budget(%Reasoning{}), do: :ok

  defp validate_output(:text), do: :ok
  defp validate_output(:json_object), do: :ok

  defp validate_output({:json_schema, _name, schema, strict})
       when is_map(schema) and strict != true, do: :ok

  defp validate_output({:json_schema, _name, _schema, true}),
    do: error("strict json_schema is not supported")

  defp validate_output(output), do: error("output #{inspect(output)} is not supported")

  defp validate_tools(tools, tool_choice) when is_list(tools) do
    with :ok <- first_error(tools, &validate_tool_spec/1),
         :ok <- validate_tool_choice(tool_choice, tools) do
      :ok
    end
  end

  defp validate_tools(_tools, _tool_choice), do: error("tools must be a list")

  defp validate_tool_spec(%ToolSpec{kind: :builtin}), do: error("builtin tools are not supported")
  defp validate_tool_spec(%ToolSpec{name: name}) when is_binary(name) and name != "", do: :ok
  defp validate_tool_spec(%ToolSpec{}), do: error("function tool requires a name")
  defp validate_tool_spec(_spec), do: error("tools must be LlmCall.ToolSpec structs")

  defp validate_tool_choice(:auto, _tools), do: :ok
  defp validate_tool_choice(:none, _tools), do: :ok

  defp validate_tool_choice(choice, []) when choice in [:required] or is_tuple(choice),
    do: error("tool_choice requires at least one tool")

  defp validate_tool_choice(:required, _tools), do: :ok
  defp validate_tool_choice({:tool, name}, _tools) when is_binary(name) and name != "", do: :ok

  defp validate_tool_choice({:tool, _name}, _tools),
    do: error("tool_choice tool name is required")

  defp validate_tool_choice({:allowed, names}, _tools) when is_list(names), do: :ok

  defp validate_tool_choice(choice, _tools),
    do: error("tool_choice #{inspect(choice)} is not supported")

  defp validate_system(nil), do: :ok
  defp validate_system(text) when is_binary(text), do: :ok
  defp validate_system(parts) when is_list(parts), do: first_error(parts, &validate_system_part/1)
  defp validate_system(_system), do: error("system must be a string or a list of content parts")

  defp validate_system_part(%Content.Text{text: text}) when is_binary(text), do: :ok
  defp validate_system_part(%Content.Text{}), do: error("system text part requires text")
  defp validate_system_part(_part), do: error("system only supports text parts")

  defp validate_parts(messages) do
    first_error(messages, fn %Message{content: content} ->
      first_error(content, &validate_part/1)
    end)
  end

  defp validate_part(%Content.Text{}), do: :ok
  defp validate_part(%Content.Thinking{}), do: :ok

  defp validate_part(%Content.Image{source: {:base64, _data}, media_type: nil}),
    do: error("base64 image requires media_type")

  defp validate_part(%Content.Image{source: {:base64, _data}}), do: :ok
  defp validate_part(%Content.Image{source: {:url, _url}}), do: :ok
  defp validate_part(%Content.Image{source: source}) when is_binary(source), do: :ok
  defp validate_part(%Content.Image{}), do: error("image source is not supported")

  defp validate_part(%Content.File{source: {:base64, _data}, media_type: nil}),
    do: error("base64 file requires media_type")

  defp validate_part(%Content.File{source: {:base64, _data}}), do: :ok
  defp validate_part(%Content.File{source: {:url, _url}}), do: :ok
  defp validate_part(%Content.File{source: source}) when is_binary(source), do: :ok
  defp validate_part(%Content.File{}), do: error("file source is not supported")
  defp validate_part(%Content.Raw{data: %{}}), do: :ok
  defp validate_part(%Content.Raw{}), do: error("raw content requires a map payload")
  defp validate_part(%ToolCall{name: nil}), do: error("tool call requires a name")
  defp validate_part(%ToolCall{} = call), do: validate_tool_call_arguments(call)
  defp validate_part(%ToolResult{name: nil}), do: error("tool result requires a name")
  defp validate_part(%ToolResult{content: content}), do: validate_tool_result_content(content)
  defp validate_part(_part), do: error("unsupported content part")

  defp validate_tool_call_arguments(%ToolCall{arguments: arguments}) when is_map(arguments),
    do: :ok

  defp validate_tool_call_arguments(%ToolCall{raw_arguments: nil}), do: :ok

  defp validate_tool_call_arguments(%ToolCall{raw_arguments: raw}) do
    case :json.decode(raw) do
      %{} -> :ok
      _not_a_map -> error("tool call raw_arguments must decode to an object")
    end
  rescue
    _decode_error -> error("tool call raw_arguments must decode to an object")
  end

  defp validate_tool_result_content(content) when is_binary(content), do: :ok

  defp validate_tool_result_content(content) when is_list(content),
    do: first_error(content, &validate_tool_result_part/1)

  defp validate_tool_result_content(_content),
    do: error("tool result content must be a string or content parts")

  defp validate_tool_result_part(%Content.Text{}), do: :ok
  defp validate_tool_result_part(_part), do: error("tool result only supports text content")

  defp validate_provider_options(request, config) do
    options = Config.provider_options(request, config)

    gemini = Map.get(options, :gemini)
    google = Map.get(options, :google)

    cond do
      not is_nil(gemini) and not is_map(gemini) -> error("provider_options.gemini must be a map")
      not is_nil(google) and not is_map(google) -> error("provider_options.google must be a map")
      true -> first_error(Map.keys(gemini || google || %{}), &validate_provider_option_key/1)
    end
  end

  defp validate_provider_option_key(key) do
    if reserved_key?(key) do
      error("provider option #{inspect(key)} would replace a canonical field")
    else
      :ok
    end
  end

  defp reserved_key?(key) do
    key |> to_string() |> String.downcase() |> then(&(&1 in @reserved_keys))
  end

  defp reject(nil, _message), do: :ok
  defp reject(_value, message), do: error(message)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp first_error(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp error(message),
    do: {:error, %Error{kind: :validation, message: "gemini_generate_content: " <> message}}

  @impl true
  def decode_response(term, %Config{} = config) when is_map(term) do
    case term["candidates"] do
      [candidate | extra] when is_map(candidate) ->
        with {:ok, parts} <- fetch_parts(candidate) do
          content =
            Enum.map(parts, &decode_part/1) ++
              Enum.map(extra, &%Content.Raw{type: "candidate", data: &1})

          {:ok,
           %Response{
             id: term["responseId"],
             model: term["modelVersion"],
             content: content,
             stop_reason: response_stop_reason(candidate["finishReason"], content),
             usage: decode_usage(term["usageMetadata"]),
             raw: capture_response(config, term)
           }}
        end

      _absent_or_empty ->
        if blocked?(term) do
          {:ok,
           %Response{
             id: term["responseId"],
             model: term["modelVersion"],
             content: [],
             stop_reason: :content_filter,
             usage: decode_usage(term["usageMetadata"]),
             raw: capture_response(config, term)
           }}
        else
          {:error, invalid_response("response has no candidates")}
        end
    end
  end

  def decode_response(_term, _config) do
    {:error, invalid_response("payload is not a JSON object")}
  end

  @impl true
  def decode_error(%{"error" => %{"message" => message} = error} = payload, _config) do
    status = error["status"]

    %Error{
      kind: :provider,
      message: message,
      code: status,
      status: error["code"],
      retryable?: status in @retryable_statuses,
      raw: payload
    }
  end

  def decode_error(_term, _config) do
    %Error{
      kind: :invalid_response,
      message: "gemini_generate_content: unrecognized error payload",
      raw: nil
    }
  end

  @impl true
  def capabilities(%Request{}, _config) do
    %Capabilities{
      tools: true,
      parallel_tool_calls: true,
      tool_choice: true,
      structured_output: :json_schema,
      image_input: true,
      file_input: true,
      reasoning: %ReasoningCapabilities{
        supported: true,
        efforts: [:none, :low, :high],
        default_effort: nil,
        budget_tokens: true,
        adaptive: false,
        summary: []
      },
      streaming_tool_calls: true,
      prompt_cache: true,
      stateful: false,
      streaming: true
    }
  end

  @impl true
  def init_stream(%Request{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      {:ok,
       StreamState.new(__MODULE__, %{
         id: nil,
         model: nil,
         next_tool_index: 0,
         usage: nil,
         stop_reason: nil,
         finished?: false
       })}
    end
  end

  @impl true
  def decode_stream_event(%{"error" => error}, %Config{} = config, %StreamState{}) do
    {:error, decode_error(%{"error" => error}, config)}
  end

  def decode_stream_event(term, %Config{} = config, %StreamState{} = state) when is_map(term) do
    data = StreamState.data(state)

    data = %{
      data
      | id: term["responseId"] || data.id,
        model: term["modelVersion"] || data.model,
        usage: accumulate_usage(data.usage, term["usageMetadata"])
    }

    {events, data} = chunk_events(term, config, data)
    {:ok, events, StreamState.new(__MODULE__, data)}
  end

  def decode_stream_event(_term, _config, %StreamState{} = state), do: {:ok, [], state}

  @impl true
  def finish_stream(%StreamState{} = state, %Config{} = config) do
    data = StreamState.data(state)

    if data.finished? do
      {:ok, [], state}
    else
      usage_events =
        if usage?(data.usage) do
          delta = %StreamDelta.MessageDelta{stop_reason: nil, usage: data.usage}
          [event(:message_delta, nil, delta, nil, config)]
        else
          []
        end

      closed = %{data | finished?: true}

      {:ok, usage_events ++ [event(:message_stop, nil, nil, nil, config)],
       StreamState.new(__MODULE__, closed)}
    end
  end

  defp fetch_parts(%{"content" => %{"parts" => parts}}) when is_list(parts), do: {:ok, parts}
  defp fetch_parts(_candidate), do: {:error, invalid_response("candidate has no content parts")}

  defp blocked?(term) do
    case term["promptFeedback"] do
      %{"blockReason" => reason} when is_binary(reason) -> true
      _other -> false
    end
  end

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "gemini_generate_content: " <> message}
  end

  defp decode_part(%{"text" => text, "thought" => true} = part) do
    %Content.Thinking{text: text, signature: part["thoughtSignature"]}
  end

  defp decode_part(%{"text" => text}) when is_binary(text), do: %Content.Text{text: text}

  defp decode_part(%{"functionCall" => call}) when is_map(call) do
    %ToolCall{
      id: nil,
      name: call["name"],
      arguments: call["args"] || %{},
      raw_arguments: nil,
      arguments_error: nil
    }
  end

  defp decode_part(%{"inlineData" => %{} = data}) do
    %Content.Image{source: {:base64, data["data"]}, media_type: data["mimeType"]}
  end

  defp decode_part(%{"fileData" => %{} = data}) do
    %Content.File{
      source: {:url, data["fileUri"]},
      media_type: data["mimeType"],
      filename: nil
    }
  end

  defp decode_part(%{"functionResponse" => %{"name" => name} = response}) do
    body = response["response"] || %{}

    %ToolResult{
      name: name,
      content: body["result"] || body["error"] || "",
      is_error: Map.has_key?(body, "error")
    }
  end

  defp decode_part(part) when is_map(part) do
    [key] = Map.keys(part)
    %Content.Raw{type: key, data: part}
  end

  defp response_stop_reason(nil, _content), do: :unknown

  defp response_stop_reason("STOP", content) do
    if Enum.any?(content, &is_struct(&1, ToolCall)), do: :tool_calls, else: :end_turn
  end

  defp response_stop_reason("MAX_TOKENS", _content), do: :max_tokens

  defp response_stop_reason(reason, _content)
       when reason in ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"] do
    :content_filter
  end

  defp response_stop_reason(_reason, _content), do: :unknown

  defp decode_usage(nil), do: nil
  defp decode_usage(%{} = usage), do: accumulate_usage(nil, usage)
  defp decode_usage(_usage), do: nil

  defp accumulate_usage(nil, nil), do: nil
  defp accumulate_usage(current, nil), do: current

  defp accumulate_usage(current, %{} = wire) do
    base = current || %Usage{}

    %Usage{
      input_tokens: wire["promptTokenCount"] || base.input_tokens,
      output_tokens: wire["candidatesTokenCount"] || base.output_tokens,
      total_tokens: wire["totalTokenCount"] || base.total_tokens,
      cache_read_tokens: wire["cachedContentTokenCount"] || base.cache_read_tokens,
      cache_write_tokens: base.cache_write_tokens,
      reasoning_tokens: wire["thoughtsTokenCount"] || base.reasoning_tokens
    }
  end

  defp usage?(nil), do: false

  defp usage?(%Usage{} = usage) do
    usage.input_tokens || usage.output_tokens || usage.total_tokens || usage.cache_read_tokens ||
      usage.reasoning_tokens
  end

  defp chunk_events(term, config, data) do
    case term["candidates"] do
      [candidate | _] when is_map(candidate) ->
        parts = get_in(candidate, ["content", "parts"]) || []
        {part_events, data} = parts_events(parts, term, config, data)

        {finish_events, data} =
          finish_events(candidate["finishReason"], parts, term, config, data)

        {part_events ++ finish_events, data}

      _absent_or_empty ->
        cond do
          blocked?(term) ->
            delta = %StreamDelta.MessageDelta{stop_reason: :content_filter, usage: nil}

            {[event(:message_delta, nil, delta, term, config)],
             %{data | stop_reason: :content_filter}}

          true ->
            {[event(:message_delta, nil, %StreamDelta.Raw{data: term}, term, config)], data}
        end
    end
  end

  defp parts_events(parts, term, config, data) do
    Enum.reduce(parts, {[], data}, fn part, {events, data} ->
      {new_events, data} = part_events(part, term, config, data)
      {events ++ new_events, data}
    end)
  end

  defp part_events(%{"functionCall" => call}, term, config, data) when is_map(call) do
    index = data.next_tool_index

    delta = %StreamDelta.ToolCall{
      id: nil,
      name: call["name"],
      arguments: LlmCall.JSON.encode(call["args"] || %{}),
      index: index
    }

    events = [
      event(:tool_call_start, index, delta, term, config),
      event(:tool_call_delta, index, delta, term, config),
      event(:tool_call_stop, index, %StreamDelta.ToolCall{index: index}, term, config)
    ]

    {events, %{data | next_tool_index: index + 1}}
  end

  defp part_events(%{"text" => text} = part, term, config, data)
       when is_binary(text) and text != "" do
    if part["thought"] == true do
      thinking = %StreamDelta.Thinking{text: text, signature: part["thoughtSignature"]}
      {[event(:thinking_delta, nil, thinking, term, config)], data}
    else
      {[event(:text_delta, nil, %StreamDelta.Text{text: text}, term, config)], data}
    end
  end

  defp part_events(_part, _term, _config, data), do: {[], data}

  defp finish_events(nil, _parts, _term, _config, data), do: {[], data}

  defp finish_events(reason, parts, term, config, data) do
    stop =
      if reason == "STOP" and Enum.any?(parts, &is_map_key(&1, "functionCall")),
        do: :tool_calls,
        else: response_stop_reason(reason, [])

    delta = %StreamDelta.MessageDelta{stop_reason: stop, usage: nil}

    {[event(:message_delta, nil, delta, term, config)], %{data | stop_reason: stop}}
  end

  defp event(type, index, delta, term, config) do
    %StreamEvent{type: type, index: index, delta: delta, raw: capture_event(config, term)}
  end

  defp capture_event(%Config{capture_raw: :all}, term) when is_map(term), do: term
  defp capture_event(_config, _term), do: nil

  defp capture_response(%Config{capture_raw: raw}, term) when raw in [:response, :all], do: term
  defp capture_response(_config, _term), do: nil
end
