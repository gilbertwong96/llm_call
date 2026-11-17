defmodule LlmDialect.Protocol.Gemini.GenerateContent do
  @moduledoc """
  Gemini `generateContent` / `streamGenerateContent` (`v1beta`).

  Messages become `contents`, where an assistant turn is `role: "model"`. System
  instructions are a top-level `systemInstruction`, sampling and output controls
  live in `generationConfig`, and reasoning maps to `thinkingConfig`.

  Gemini identifies a tool result by function `name`, not by a call id, so
  `LlmDialect.ToolResult.call_id` is not represented on this protocol. A request
  without a function `name` on the result is rejected.

  Streaming changes the method in the path (`:streamGenerateContent`) and adds
  `alt=sse` to the query; the transport still owns SSE framing.
  """

  @api_version "v1beta"
  @headers [{"content-type", "application/json"}]
  @envelope_keys ~w(model messages system contents tools stream systeminstruction toolconfig)
  @default_reserved_keys @envelope_keys ++ ~w(generationconfig)
  @param_keys [:temperature, :top_p, :top_k, :max_tokens, :stop]
  @efforts [nil, :none, :low, :high]
  @retryable_statuses ~w(RESOURCE_EXHAUSTED UNAVAILABLE INTERNAL DEADLINE_EXCEEDED)

  use LlmDialect.Protocol.Adapter, codec: :gemini_generate_content, encode: false

  @impl true
  @spec info() :: LlmDialect.Codec.Info.t()
  def info do
    %LlmDialect.Codec.Info{
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
         :ok <- validate_output_modalities(request.modalities),
         :ok <- Helpers.validate_modalities(request.modalities, [:text, :image], @codec),
         :ok <- validate_streaming_modalities(request),
         :ok <- validate_messages(request.messages),
         :ok <- validate_params(request.params),
         :ok <- validate_reasoning(request.reasoning),
         :ok <- validate_output(request.output),
         :ok <-
           Helpers.validate_tools(
             request.tools,
             request.tool_choice,
             @codec,
             &validate_tool_spec/1,
             &validate_tool_choice/2
           ),
         :ok <- Helpers.validate_system(request.system, @codec),
         :ok <- validate_parts(request.messages) do
      validate_provider_options(request, config)
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
    |> Helpers.maybe_put("systemInstruction", encode_system(request.system))
    |> Helpers.maybe_put("tools", encode_tools(request.tools))
    |> Helpers.maybe_put("toolConfig", encode_tool_config(request.tool_choice, request.tools))
    |> Helpers.maybe_put("generationConfig", encode_generation_config(request))
    |> Config.deep_merge(provider_options(request, config))
  end

  defp encode_message(%Message{role: role, content: content}) do
    %{
      "role" => if(role == :assistant, do: "model", else: "user"),
      "parts" => Enum.map(content, &encode_part/1)
    }
  end

  defp encode_system(nil), do: nil
  defp encode_system([]), do: nil

  defp encode_system(text) when is_binary(text) do
    %{"parts" => [%{"text" => text}]}
  end

  defp encode_system(parts) when is_list(parts) do
    %{"parts" => Enum.map(parts, fn %Content.Text{text: text} -> %{"text" => text} end)}
  end

  defp encode_part(%Content.Text{text: text}), do: %{"text" => text}

  defp encode_part(%Content.Thinking{text: text, signature: signature}) do
    %{"text" => text, "thought" => true} |> Helpers.maybe_put("thoughtSignature", signature)
  end

  defp encode_part(%Content.Image{source: {:base64, data}, media_type: media_type}) do
    %{"inlineData" => %{"mimeType" => media_type, "data" => data}}
  end

  defp encode_part(%Content.Image{source: {:url, url}, media_type: media_type}) do
    %{"fileData" => %{"fileUri" => url} |> Helpers.maybe_put("mimeType", media_type)}
  end

  defp encode_part(%Content.Image{source: url}) when is_binary(url) do
    %{"fileData" => %{"fileUri" => url}}
  end

  defp encode_part(%Content.File{source: {:base64, data}, media_type: media_type}) do
    %{"inlineData" => %{"mimeType" => media_type, "data" => data}}
  end

  defp encode_part(%Content.File{source: {:url, url}, media_type: media_type}) do
    %{"fileData" => %{"fileUri" => url} |> Helpers.maybe_put("mimeType", media_type)}
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

  defp decode_raw_arguments(%ToolCall{raw_arguments: raw}),
    do: Helpers.decode_raw_arguments(raw)

  defp encode_tools([]), do: nil

  defp encode_tools(specs) do
    declarations =
      Enum.map(specs, fn %ToolSpec{} = spec ->
        %{"name" => spec.name}
        |> Helpers.maybe_put("description", spec.description)
        |> Helpers.maybe_put("parameters", spec.parameters)
        |> Config.deep_merge(tool_options(spec))
      end)

    [%{"functionDeclarations" => declarations}]
  end

  defp tool_options(%ToolSpec{provider_options: options}) when is_map(options), do: options
  defp tool_options(_spec), do: %{}

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
      |> Helpers.maybe_put("temperature", request.params[:temperature])
      |> Helpers.maybe_put("topP", request.params[:top_p])
      |> Helpers.maybe_put("topK", request.params[:top_k])
      |> Helpers.maybe_put("maxOutputTokens", request.params[:max_tokens])
      |> Helpers.maybe_put("stopSequences", request.params[:stop])
      |> Map.merge(encode_output(request.output))
      |> Helpers.maybe_put("thinkingConfig", encode_thinking(request.reasoning))
      |> Helpers.maybe_put("responseModalities", encode_modalities(request.modalities))

    if config == %{}, do: nil, else: config
  end

  defp encode_modalities([:text]), do: nil

  defp encode_modalities(modalities) do
    Enum.map(modalities, &(&1 |> Atom.to_string() |> String.upcase()))
  end

  defp encode_output(:text), do: %{}
  defp encode_output(:json_object), do: %{"responseMimeType" => "application/json"}

  defp encode_output({:json_schema, _name, schema, _strict}) do
    %{"responseMimeType" => "application/json", "responseSchema" => schema}
  end

  defp encode_thinking(nil), do: nil

  defp encode_thinking(%Reasoning{} = reasoning) do
    base =
      cond do
        is_integer(reasoning.budget_tokens) ->
          %{"thinkingBudget" => reasoning.budget_tokens}

        reasoning.effort == :none ->
          %{"thinkingBudget" => 0}

        reasoning.effort in [:low, :high] ->
          %{"thinkingLevel" => Atom.to_string(reasoning.effort)}

        true ->
          %{}
      end

    case Config.deep_merge(base, reasoning_options(reasoning)) do
      merged when map_size(merged) == 0 -> nil
      merged -> merged
    end
  end

  defp reasoning_options(%Reasoning{provider_options: options}) when is_map(options), do: options

  defp provider_options(request, config) do
    config.default_provider_options
    |> native_options()
    |> Config.deep_merge(native_options(request.provider_options))
  end

  defp native_options(options) do
    google = Map.get(options, :google)
    gemini = Map.get(options, :gemini)

    case {google, gemini} do
      {nil, nil} -> %{}
      {google, nil} -> google
      {nil, gemini} -> gemini
      {google, gemini} -> Config.deep_merge(google, gemini)
    end
  end

  defp validate_output_modalities(modalities) do
    valid? =
      is_list(modalities) and Enum.all?(modalities, &(&1 in [:text, :image, :video]))

    if valid? and :video in modalities do
      Helpers.error(@codec, "video output requires the long-running predict path")
    else
      :ok
    end
  end

  defp validate_streaming_modalities(%Request{stream: true, modalities: modalities}) do
    if :image in modalities do
      Helpers.error(@codec, "image output cannot be streamed")
    else
      :ok
    end
  end

  defp validate_streaming_modalities(%Request{}), do: :ok

  defp validate_model(model), do: Helpers.validate_model_id(model, @codec)

  defp validate_messages(messages), do: Helpers.validate_messages(messages, @codec)

  defp validate_params(params), do: Helpers.validate_params(params, @param_keys, @codec)

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%Reasoning{} = reasoning) do
    with :ok <- validate_effort(reasoning.effort),
         :ok <- validate_budget(reasoning.budget_tokens),
         :ok <- Helpers.reject(reasoning.summary, @codec, "reasoning summary is not supported"),
         :ok <- reject_effort_with_budget(reasoning) do
      Helpers.validate_options(
        reasoning.provider_options,
        @codec,
        "reasoning.provider_options"
      )
    end
  end

  defp validate_reasoning(_reasoning),
    do: Helpers.error(@codec, "reasoning must be a LlmDialect.Reasoning struct")

  defp validate_effort(effort) when effort in @efforts, do: :ok

  defp validate_effort(effort),
    do: Helpers.error(@codec, "reasoning effort #{inspect(effort)} is not supported")

  defp validate_budget(nil), do: :ok
  defp validate_budget(budget) when is_integer(budget) and budget > 0, do: :ok

  defp validate_budget(_budget),
    do: Helpers.error(@codec, "reasoning budget_tokens must be a positive integer")

  defp reject_effort_with_budget(%Reasoning{budget_tokens: budget, effort: effort})
       when not is_nil(budget) and not is_nil(effort) do
    Helpers.error(@codec, "reasoning budget_tokens and effort cannot be combined")
  end

  defp reject_effort_with_budget(%Reasoning{}), do: :ok

  defp validate_output(:text), do: :ok
  defp validate_output(:json_object), do: :ok

  defp validate_output({:json_schema, name, schema, strict})
       when is_binary(name) and name != "" and is_map(schema) and
              (is_boolean(strict) or is_nil(strict)) and strict != true,
       do: :ok

  defp validate_output({:json_schema, _name, _schema, true}),
    do: Helpers.error(@codec, "strict json_schema is not supported")

  defp validate_output(output),
    do: Helpers.error(@codec, "output #{inspect(output)} is not supported")

  defp validate_tool_spec(spec), do: Helpers.validate_tool_spec(spec, @codec, options: true)

  defp validate_tool_choice(:auto, _tools), do: :ok
  defp validate_tool_choice(:none, _tools), do: :ok

  defp validate_tool_choice(choice, []) when choice in [:required] or is_tuple(choice),
    do: Helpers.error(@codec, "tool_choice requires at least one tool")

  defp validate_tool_choice(:required, _tools), do: :ok
  defp validate_tool_choice({:tool, name}, _tools) when is_binary(name) and name != "", do: :ok

  defp validate_tool_choice({:tool, _name}, _tools),
    do: Helpers.error(@codec, "tool_choice tool name is required")

  defp validate_tool_choice({:allowed, names}, _tools) when is_list(names), do: :ok

  defp validate_tool_choice(choice, _tools),
    do: Helpers.error(@codec, "tool_choice #{inspect(choice)} is not supported")

  defp validate_parts(messages),
    do: Helpers.validate_parts(messages, @codec, &validate_part_shape/2)

  defp validate_part_shape(_role, %Content.Text{}), do: :ok
  defp validate_part_shape(_role, %Content.Thinking{}), do: :ok

  defp validate_part_shape(_role, %Content.Image{source: {:base64, _data}, media_type: nil}),
    do: Helpers.error(@codec, "base64 image requires media_type")

  defp validate_part_shape(_role, %Content.Image{source: {:base64, _data}}), do: :ok
  defp validate_part_shape(_role, %Content.Image{source: {:url, _url}}), do: :ok

  defp validate_part_shape(_role, %Content.Image{source: source}) when is_binary(source),
    do: :ok

  defp validate_part_shape(_role, %Content.Image{}),
    do: Helpers.error(@codec, "image source is not supported")

  defp validate_part_shape(_role, %Content.File{source: {:base64, _data}, media_type: nil}),
    do: Helpers.error(@codec, "base64 file requires media_type")

  defp validate_part_shape(_role, %Content.File{source: {:base64, _data}}), do: :ok
  defp validate_part_shape(_role, %Content.File{source: {:url, _url}}), do: :ok

  defp validate_part_shape(_role, %Content.File{source: source}) when is_binary(source),
    do: :ok

  defp validate_part_shape(_role, %Content.File{}),
    do: Helpers.error(@codec, "file source is not supported")

  defp validate_part_shape(_role, %Content.Raw{data: %{}}), do: :ok

  defp validate_part_shape(_role, %Content.Raw{}),
    do: Helpers.error(@codec, "raw content requires a map payload")

  defp validate_part_shape(_role, %ToolCall{name: nil}),
    do: Helpers.error(@codec, "tool call requires a name")

  defp validate_part_shape(_role, %ToolCall{} = call), do: validate_tool_call_arguments(call)

  defp validate_part_shape(_role, %ToolResult{name: nil}),
    do: Helpers.error(@codec, "tool result requires a name")

  defp validate_part_shape(_role, %ToolResult{content: content}),
    do: validate_tool_result_content(content)

  defp validate_part_shape(_role, _part), do: Helpers.error(@codec, "unsupported content part")

  defp validate_tool_call_arguments(call),
    do: Helpers.validate_tool_call_arguments(call, @codec)

  defp validate_tool_result_content(content),
    do: Helpers.validate_tool_result_content(content, @codec)

  defp validate_provider_options(request, config) do
    with :ok <- Helpers.validate_option_map(request.provider_options, @codec, "provider_options"),
         :ok <-
           Helpers.validate_option_map(
             config.default_provider_options,
             @codec,
             "default_provider_options"
           ),
         :ok <- validate_namespaces(request.provider_options, "provider_options"),
         :ok <- validate_namespaces(config.default_provider_options, "default_provider_options"),
         :ok <-
           Helpers.validate_option_keys(
             native_options(request.provider_options),
             @envelope_keys,
             @codec
           ) do
      Helpers.validate_option_keys(
        native_options(config.default_provider_options),
        @default_reserved_keys,
        @codec
      )
    end
  end

  defp validate_namespaces(options, label) do
    Helpers.first_error([:gemini, :google], fn key ->
      case Map.get(options, key) do
        nil -> :ok
        value when is_map(value) -> :ok
        _other -> Helpers.error(@codec, "#{label}.#{key} must be a map")
      end
    end)
  end

  @impl true
  def decode_response(term, %Config{} = config) when is_map(term) do
    case term["candidates"] do
      [candidate | extra] when is_map(candidate) ->
        case fetch_parts(candidate) do
          {:ok, parts} ->
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
               raw: Helpers.capture_response(config, term)
             }}

          {:error, _error} = error ->
            candidate_without_content(candidate, extra, term, config, error)
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
             raw: Helpers.capture_response(config, term)
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
  def decode_error(payload, _config) do
    Helpers.decode_provider_error(payload, @codec, ["status"], @retryable_statuses)
  end

  @impl true
  def capabilities(%Request{}, _config) do
    %Capabilities{
      tools: true,
      parallel_tool_calls: true,
      tool_choice: true,
      structured_output: :json_schema,
      modalities: [:text, :image],
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
          [Helpers.event(:message_delta, nil, delta, nil, config)]
        else
          []
        end

      closed = %{data | finished?: true}

      {:ok, usage_events ++ [Helpers.event(:message_stop, nil, nil, nil, config)],
       StreamState.new(__MODULE__, closed)}
    end
  end

  defp fetch_parts(%{"content" => %{"parts" => parts}}) when is_list(parts), do: {:ok, parts}
  defp fetch_parts(_candidate), do: {:error, invalid_response("candidate has no content parts")}

  defp candidate_without_content(candidate, extra, term, config, error) do
    case candidate["finishReason"] do
      reason when is_binary(reason) ->
        {:ok,
         %Response{
           id: term["responseId"],
           model: term["modelVersion"],
           content: Enum.map(extra, &%Content.Raw{type: "candidate", data: &1}),
           stop_reason: response_stop_reason(reason, []),
           usage: decode_usage(term["usageMetadata"]),
           raw: Helpers.capture_response(config, term)
         }}

      _other ->
        error
    end
  end

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
    %Content.Raw{type: part |> Map.keys() |> Enum.sort() |> List.first(), data: part}
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
        if blocked?(term) do
          delta = %StreamDelta.MessageDelta{stop_reason: :content_filter, usage: nil}

          {[Helpers.event(:message_delta, nil, delta, term, config)],
           %{data | stop_reason: :content_filter}}
        else
          {[Helpers.event(:message_delta, nil, %StreamDelta.Raw{data: term}, term, config)], data}
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
      arguments: LlmDialect.JSON.encode(call["args"] || %{}),
      index: index
    }

    events = [
      Helpers.event(:tool_call_start, index, delta, term, config),
      Helpers.event(:tool_call_delta, index, delta, term, config),
      Helpers.event(:tool_call_stop, index, %StreamDelta.ToolCall{index: index}, term, config)
    ]

    {events, %{data | next_tool_index: index + 1}}
  end

  defp part_events(%{"text" => text} = part, term, config, data)
       when is_binary(text) and text != "" do
    if part["thought"] == true do
      thinking = %StreamDelta.Thinking{text: text, signature: part["thoughtSignature"]}
      {[Helpers.event(:thinking_delta, nil, thinking, term, config)], data}
    else
      {[Helpers.event(:text_delta, nil, %StreamDelta.Text{text: text}, term, config)], data}
    end
  end

  defp part_events(_part, _term, _config, data), do: {[], data}

  defp finish_events(nil, _parts, _term, _config, data), do: {[], data}

  defp finish_events(reason, parts, term, config, data) do
    stop =
      cond do
        reason != "STOP" -> response_stop_reason(reason, [])
        Enum.any?(parts, &is_map_key(&1, "functionCall")) -> :tool_calls
        data.next_tool_index > 0 -> :tool_calls
        true -> :end_turn
      end

    delta = %StreamDelta.MessageDelta{stop_reason: stop, usage: nil}

    {[Helpers.event(:message_delta, nil, delta, term, config)], %{data | stop_reason: stop}}
  end
end
