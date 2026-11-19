defmodule LlmCall.Protocol.OpenAI.Chat do
  @moduledoc """
  OpenAI Chat Completions (`POST /v1/chat/completions`).

  OpenAI-compatible providers use this codec too; their differences belong in
  `LlmCall.Request.provider_options` and the transport's base URL, not in a new
  protocol.

  System instructions become a leading `system` message. Tool results become
  `role: "tool"` messages, emitted before the message's remaining content
  because OpenAI requires them directly after the assistant tool call.
  """

  @path "/v1/chat/completions"
  @headers [{"content-type", "application/json"}]
  @envelope_keys ~w(model messages tools tool_choice response_format reasoning_effort stream)
  @default_reserved_keys @envelope_keys ++
                           ~w(temperature top_p max_tokens stop seed)
  @stream_reserved_keys ~w(include_usage)
  @tool_reserved_keys ~w(name description parameters strict)
  @builtin_tools false
  @param_keys [:temperature, :top_p, :max_tokens, :stop, :seed]
  @efforts [:none, :minimal, :low, :medium, :high]
  @retryable_codes ~w(rate_limit_exceeded rate_limit_error server_error overloaded_error timeout)
  @known_message_keys ["role", "content", "tool_calls", "reasoning_content", "refusal"]
  @known_delta_keys ["content", "reasoning_content", "tool_calls"]

  @namespaces [:openai]

  @native_options %{
    "logprobs" => :boolean,
    "top_logprobs" => :integer,
    "logit_bias" => :map,
    "stream_options" => :map,
    "parallel_tool_calls" => :boolean,
    "service_tier" => :string,
    "user" => :string,
    "store" => :boolean,
    "metadata" => :map,
    "prediction" => :map,
    "modalities" => :list,
    "audio" => :map,
    "web_search_options" => :map
  }

  use LlmCall.Protocol.Adapter, codec: :openai_chat

  @impl true
  @spec info() :: LlmCall.Codec.Info.t()
  def info do
    %LlmCall.Codec.Info{
      name: :openai_chat,
      protocol: :openai_chat,
      version: nil,
      ir_version: 1
    }
  end

  @impl true
  @spec validate_request(Request.t(), Config.t()) :: :ok | {:error, Error.t()}
  def validate_request(%Request{} = request, %Config{} = config) do
    with :ok <- validate_model(request.model),
         :ok <- Helpers.validate_modalities(request.modalities, [:text], @codec),
         :ok <- validate_messages(request.messages),
         :ok <- validate_params(request.params),
         :ok <- validate_output(request.output),
         :ok <- validate_reasoning(request.reasoning),
         :ok <-
           Helpers.validate_tools(
             request.tools,
             request.tool_choice,
             @codec,
             &validate_tool_spec/1,
             &validate_tool_choice/2
           ),
         :ok <- Helpers.validate_system(request.system, @codec),
         :ok <- validate_parts(request.messages, config.json) do
      validate_provider_options(request, config)
    end
  end

  defp body(request, config) do
    with {:ok, messages} <- messages(request, config.json) do
      body =
        %{}
        |> Map.put("model", request.model)
        |> Map.put("messages", messages)
        |> Helpers.maybe_put("tools", encode_tools(request.tools))
        |> Helpers.maybe_put("tool_choice", encode_tool_choice(request.tool_choice))
        |> Helpers.maybe_put("response_format", encode_response_format(request.output))
        |> Helpers.maybe_put("reasoning_effort", encode_reasoning_effort(request.reasoning))
        |> Map.merge(encode_params(request.params))
        |> put_stream(request.stream)
        |> Config.deep_merge(reasoning_provider_options(request.reasoning))
        |> Config.deep_merge(provider_options(request, config))

      {:ok, body}
    end
  end

  defp messages(request, json) do
    with {:ok, system} <- system_messages(request.system, json),
         {:ok, encoded} <- Helpers.map_ok(request.messages, &encode_message(&1, json)) do
      {:ok, system ++ List.flatten(encoded)}
    end
  end

  defp system_messages(nil, _json), do: {:ok, []}
  defp system_messages([], _json), do: {:ok, []}

  defp system_messages(text, _json) when is_binary(text) do
    {:ok, [%{"role" => "system", "content" => text}]}
  end

  defp system_messages(parts, json) when is_list(parts) do
    with {:ok, encoded} <- Helpers.map_ok(parts, &encode_part(&1, json)) do
      {:ok, [%{"role" => "system", "content" => encoded}]}
    end
  end

  defp encode_message(%Message{role: :user, content: content}, json) do
    {results, other_parts} = Enum.split_with(content, &is_struct(&1, ToolResult))

    tool_messages = Enum.map(results, &encode_tool_result/1)

    case other_parts do
      [] ->
        {:ok, tool_messages}

      parts ->
        with {:ok, encoded} <- Helpers.map_ok(parts, &encode_part(&1, json)) do
          {:ok, tool_messages ++ [%{"role" => "user", "content" => encoded}]}
        end
    end
  end

  defp encode_message(%Message{role: :assistant, content: content}, json) do
    calls = Enum.filter(content, &is_struct(&1, ToolCall))
    texts = Enum.filter(content, &is_struct(&1, Content.Text))

    text_content =
      case texts do
        [] -> nil
        parts -> Enum.map(parts, &(encode_part(&1, json) |> elem(1)))
      end

    message = %{"role" => "assistant", "content" => text_content}

    case calls do
      [] ->
        {:ok, [message]}

      calls ->
        with {:ok, encoded} <- Helpers.map_ok(calls, &encode_tool_call(&1, json)) do
          {:ok, [Map.put(message, "tool_calls", encoded)]}
        end
    end
  end

  defp encode_part(%Content.Text{text: text}, _json),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp encode_part(%Content.Image{source: source, media_type: media_type}, _json) do
    {:ok, %{"type" => "image_url", "image_url" => %{"url" => image_url(source, media_type)}}}
  end

  defp image_url({:base64, data}, media_type), do: "data:#{media_type};base64,#{data}"
  defp image_url({:url, url}, _media_type), do: url
  defp image_url(url, _media_type) when is_binary(url), do: url

  defp encode_tool_call(%ToolCall{} = call, json) do
    with {:ok, arguments} <- encode_call_arguments(call, json) do
      {:ok,
       %{
         "id" => call.id,
         "type" => "function",
         "function" => %{"name" => call.name, "arguments" => arguments}
       }}
    end
  end

  defp encode_call_arguments(call, json), do: Helpers.encode_call_arguments(call, @codec, json)

  defp encode_tool_result(%ToolResult{} = result) do
    %{
      "role" => "tool",
      "tool_call_id" => result.call_id,
      "content" => tool_result_text(result.content)
    }
  end

  defp tool_result_text(content) when is_binary(content), do: content
  defp tool_result_text(parts) when is_list(parts), do: Enum.map_join(parts, "\n", & &1.text)

  defp encode_tools([]), do: nil
  defp encode_tools(specs), do: Enum.map(specs, &encode_tool_spec/1)

  defp encode_tool_spec(%ToolSpec{} = spec) do
    %{
      "type" => "function",
      "function" =>
        %{"name" => spec.name}
        |> Helpers.maybe_put("description", spec.description)
        |> Helpers.maybe_put("parameters", spec.parameters)
        |> Helpers.maybe_put("strict", spec.strict)
        |> Config.deep_merge(tool_provider_options(spec))
    }
  end

  defp reasoning_provider_options(%Reasoning{provider_options: options}) when is_map(options),
    do: options

  defp reasoning_provider_options(_reasoning), do: %{}

  defp tool_provider_options(%ToolSpec{provider_options: options}) when is_map(options),
    do: options

  defp tool_provider_options(_spec), do: %{}

  defp encode_tool_choice(:auto), do: nil
  defp encode_tool_choice(:none), do: "none"
  defp encode_tool_choice(:required), do: "required"

  defp encode_tool_choice({:tool, name}) do
    %{"type" => "function", "function" => %{"name" => name}}
  end

  defp encode_response_format(:text), do: nil
  defp encode_response_format(:json_object), do: %{"type" => "json_object"}

  defp encode_response_format({:json_schema, name, schema, strict}) do
    %{
      "type" => "json_schema",
      "json_schema" =>
        %{"name" => name, "schema" => schema}
        |> Helpers.maybe_put("strict", strict)
    }
  end

  defp encode_reasoning_effort(nil), do: nil
  defp encode_reasoning_effort(%Reasoning{effort: nil}), do: nil
  defp encode_reasoning_effort(%Reasoning{effort: effort}), do: Atom.to_string(effort)

  defp encode_params(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp put_stream(body, false), do: body

  defp put_stream(body, true) do
    body
    |> Map.put("stream", true)
    |> Map.put("stream_options", %{"include_usage" => true})
  end

  defp provider_options(request, config) do
    Config.provider_options(request, config) |> Map.get(:openai, %{})
  end

  defp validate_model(model), do: Helpers.validate_model(model, @codec)

  defp validate_messages(messages), do: Helpers.validate_messages(messages, @codec)

  defp validate_params(params), do: Helpers.validate_params(params, @param_keys, @codec)

  defp validate_output(output), do: Helpers.validate_output(output, @codec)

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%Reasoning{} = reasoning) do
    with :ok <- validate_effort(reasoning.effort),
         :ok <-
           Helpers.reject(
             reasoning.budget_tokens,
             @codec,
             "reasoning budget_tokens is not supported"
           ),
         :ok <-
           Helpers.validate_options(
             reasoning.provider_options,
             @codec,
             "reasoning.provider_options"
           ),
         :ok <-
           Helpers.validate_option_keys(
             reasoning.provider_options,
             @default_reserved_keys,
             @codec
           ),
         :ok <- validate_stream_options(reasoning.provider_options) do
      Helpers.reject(reasoning.summary, @codec, "reasoning summary is not supported")
    end
  end

  defp validate_reasoning(_reasoning),
    do: Helpers.error(@codec, "reasoning must be a LlmCall.Reasoning struct")

  defp validate_effort(effort), do: Helpers.validate_effort(effort, @efforts, @codec)

  defp validate_tool_spec(spec) do
    with :ok <- Helpers.validate_tool_spec(spec, @codec, strict: true, options: true) do
      Helpers.validate_option_keys(spec.provider_options, @tool_reserved_keys, @codec)
    end
  end

  defp validate_tool_choice(choice, tools),
    do: Helpers.validate_tool_choice(choice, tools, @codec)

  defp validate_parts(messages, json) do
    Helpers.validate_parts(messages, @codec, fn role, part ->
      validate_part(role, part, json)
    end)
  end

  defp validate_part(:assistant, %Content.Image{}, _json),
    do: Helpers.error(@codec, "images belong to user messages")

  defp validate_part(_role, %Content.Thinking{}, _json),
    do: Helpers.error(@codec, "thinking content is not supported in a request")

  defp validate_part(role, part, json) do
    with :ok <- Helpers.validate_role(role, part, @codec) do
      validate_part_shape(role, part, json)
    end
  end

  defp validate_part_shape(_role, %Content.Text{}, _json), do: :ok

  defp validate_part_shape(
         _role,
         %Content.Image{source: {:base64, _data}, media_type: nil},
         _json
       ),
       do: Helpers.error(@codec, "base64 image requires media_type")

  defp validate_part_shape(_role, %Content.Image{source: {:base64, _data}}, _json), do: :ok
  defp validate_part_shape(_role, %Content.Image{source: {:url, _url}}, _json), do: :ok

  defp validate_part_shape(_role, %Content.Image{source: source}, _json)
       when is_binary(source),
       do: :ok

  defp validate_part_shape(_role, %Content.Image{}, _json),
    do: Helpers.error(@codec, "image source is not supported")

  defp validate_part_shape(_role, %Content.File{}, _json),
    do: Helpers.error(@codec, "file content is not supported")

  defp validate_part_shape(_role, %Content.Raw{}, _json),
    do: Helpers.error(@codec, "raw content is not supported in a request")

  defp validate_part_shape(_role, %ToolCall{id: nil}, _json),
    do: Helpers.error(@codec, "tool call requires an id")

  defp validate_part_shape(_role, %ToolCall{name: nil}, _json),
    do: Helpers.error(@codec, "tool call requires a name")

  defp validate_part_shape(_role, %ToolCall{} = call, json),
    do: Helpers.validate_tool_call_arguments(call, @codec, json)

  defp validate_part_shape(_role, %ToolResult{call_id: nil}, _json),
    do: Helpers.error(@codec, "tool result requires call_id")

  defp validate_part_shape(_role, %ToolResult{content: content}, _json),
    do: validate_tool_result_content(content)

  defp validate_part_shape(_role, _part, _json),
    do: Helpers.error(@codec, "unsupported content part")

  defp validate_tool_result_content(content),
    do: Helpers.validate_tool_result_content(content, @codec)

  defp validate_provider_options(request, config) do
    with :ok <-
           Helpers.validate_option_map(
             request.provider_options,
             @codec,
             "provider_options",
             @namespaces
           ),
         :ok <-
           Helpers.validate_option_map(
             config.default_provider_options,
             @codec,
             "default_provider_options",
             @namespaces,
             strict?: false
           ),
         request_options = Map.get(request.provider_options, :openai, %{}),
         default_options = Map.get(config.default_provider_options, :openai, %{}),
         :ok <- Helpers.validate_option_keys(request_options, @envelope_keys, @codec),
         :ok <- Helpers.validate_option_keys(default_options, @default_reserved_keys, @codec),
         :ok <-
           Helpers.validate_native_options(
             request_options,
             @native_options,
             @codec,
             "provider_options"
           ),
         :ok <-
           Helpers.validate_native_options(
             default_options,
             @native_options,
             @codec,
             "default_provider_options"
           ),
         :ok <- validate_stream_options(request_options) do
      validate_stream_options(default_options)
    end
  end

  defp validate_stream_options(options) do
    case Map.get(options, "stream_options") do
      nil ->
        :ok

      value when is_map(value) ->
        Helpers.validate_option_keys(value, @stream_reserved_keys, @codec)

      _other ->
        Helpers.error(@codec, "provider_options.stream_options must be a map")
    end
  end

  @impl true
  def decode_response(term, %Config{} = config) when is_map(term) do
    with {:ok, choice} <- first_choice(term),
         {:ok, message} <- fetch_message(choice),
         {:ok, content} <- message_content(message, config) do
      {:ok,
       %Response{
         id: term["id"],
         model: term["model"],
         content: content ++ extra_choices(term),
         stop_reason: stop_reason(choice["finish_reason"]),
         usage: decode_usage(term["usage"]),
         raw: Helpers.capture_response(config, term)
       }}
    end
  end

  def decode_response(_term, _config) do
    {:error,
     %Error{kind: :invalid_response, message: "openai_chat: payload is not a JSON object"}}
  end

  @impl true
  def decode_error(payload, _config) do
    Helpers.decode_provider_error(payload, @codec, ["code", "type"], @retryable_codes)
  end

  @impl true
  def capabilities(%Request{}, _config) do
    %Capabilities{
      tools: true,
      builtin_tools: @builtin_tools,
      parallel_tool_calls: true,
      tool_choice: true,
      structured_output: :json_schema,
      modalities: [:text],
      image_input: true,
      file_input: false,
      reasoning: %ReasoningCapabilities{
        supported: true,
        efforts: @efforts,
        default_effort: nil,
        budget_tokens: false,
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
         usage: nil,
         tool_indexes: [],
         finished?: false
       })}
    end
  end

  @impl true
  def decode_stream_event("[DONE]", _config, %StreamState{} = state), do: {:done, state}

  def decode_stream_event(%{"error" => _} = term, %Config{} = config, %StreamState{}) do
    {:error, decode_error(term, config)}
  end

  def decode_stream_event(term, %Config{} = config, %StreamState{} = state) when is_map(term) do
    data = StreamState.data(state)
    {events, data} = chunk_events(term, config, data)
    {:ok, events, StreamState.new(__MODULE__, data)}
  end

  def decode_stream_event(term, _config, _state) do
    {:error, invalid_response("stream chunk is not an object: #{inspect(term)}")}
  end

  @impl true
  def finish_stream(%StreamState{} = state, %Config{} = config) do
    data = StreamState.data(state)

    if data.finished? do
      {:ok, [], state}
    else
      closed = %{data | finished?: true}

      {:ok, [Helpers.event(:message_stop, nil, nil, nil, config)],
       StreamState.new(__MODULE__, closed)}
    end
  end

  defp first_choice(%{"choices" => [choice | _]}) when is_map(choice), do: {:ok, choice}
  defp first_choice(%{"choices" => []}), do: {:error, invalid_response("response has no choices")}
  defp first_choice(_term), do: {:error, invalid_response("response has no choices")}

  defp fetch_message(%{"message" => message}) when is_map(message), do: {:ok, message}
  defp fetch_message(_choice), do: {:error, invalid_response("choice has no message")}

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "openai_chat: " <> message}
  end

  defp message_content(message, config) do
    with {:ok, tool_calls} <- decode_tool_calls(message["tool_calls"], config) do
      {:ok,
       thinking_content(message) ++
         text_content(message) ++
         tool_calls ++
         refusal_content(message) ++
         unknown_content(message)}
    end
  end

  defp decode_tool_calls(nil, _config), do: {:ok, []}

  defp decode_tool_calls(calls, config) when is_list(calls) do
    Helpers.map_ok(calls, &decode_tool_call(&1, config))
  end

  defp decode_tool_calls(_calls, _config) do
    {:error, invalid_response("tool_calls must be a list")}
  end

  defp thinking_content(%{"reasoning_content" => text})
       when is_binary(text) and text != "" do
    [%Content.Thinking{text: text, signature: nil}]
  end

  defp thinking_content(_message), do: []

  defp text_content(%{"content" => text}) when is_binary(text) and text != "" do
    [%Content.Text{text: text}]
  end

  defp text_content(%{"content" => value}) when not is_nil(value) and not is_binary(value) do
    [%Content.Raw{type: "content", data: %{"content" => value}}]
  end

  defp text_content(_message), do: []

  defp refusal_content(%{"refusal" => text}) when is_binary(text) do
    [%Content.Raw{type: "refusal", data: %{"refusal" => text}}]
  end

  defp refusal_content(_message), do: []

  defp unknown_content(message) do
    for {key, value} <- message,
        key not in @known_message_keys,
        not is_nil(value),
        do: %Content.Raw{type: key, data: %{key => value}}
  end

  defp decode_tool_call(entry, config) when is_map(entry) do
    case entry["function"] do
      nil ->
        decode_tool_call(entry, %{}, config)

      function when is_map(function) ->
        decode_tool_call(entry, function, config)

      _other ->
        {:error, invalid_response("tool call function is not an object")}
    end
  end

  defp decode_tool_call(_entry, _config) do
    {:error, invalid_response("tool call is not an object")}
  end

  defp decode_tool_call(entry, function, config) do
    raw = function["arguments"]
    {arguments, arguments_error} = decode_arguments(raw, config.json)

    {:ok,
     %ToolCall{
       id: entry["id"],
       name: function["name"],
       arguments: arguments,
       raw_arguments: raw,
       arguments_error: arguments_error
     }}
  end

  defp decode_arguments(raw, json), do: Helpers.decode_arguments(raw, json)

  defp extra_choices(term) do
    term
    |> Map.get("choices", [])
    |> Enum.drop(1)
    |> Enum.map(&%Content.Raw{type: "choice", data: &1})
  end

  defp stop_reason("stop"), do: :end_turn
  defp stop_reason("length"), do: :max_tokens
  defp stop_reason("tool_calls"), do: :tool_calls
  defp stop_reason("function_call"), do: :tool_calls
  defp stop_reason("content_filter"), do: :content_filter
  defp stop_reason(_other), do: :unknown

  defp decode_usage(nil), do: nil

  defp decode_usage(%{} = usage) do
    %Usage{
      input_tokens: usage["prompt_tokens"],
      output_tokens: usage["completion_tokens"],
      total_tokens: usage["total_tokens"],
      cache_read_tokens: get_in(usage, ["prompt_tokens_details", "cached_tokens"]),
      cache_write_tokens: nil,
      reasoning_tokens: get_in(usage, ["completion_tokens_details", "reasoning_tokens"])
    }
  end

  defp decode_usage(_usage), do: nil

  defp chunk_events(term, %Config{} = config, data) do
    case term["choices"] do
      [choice | _] when is_map(choice) ->
        choice_events(choice, term, config, data)

      empty when empty in [nil, []] ->
        if is_map(term["usage"]) do
          usage_tail(term, config, data)
        else
          {[raw_delta(term, config)], data}
        end

      _other ->
        {[raw_delta(term, config)], data}
    end
  end

  defp choice_events(choice, term, config, data) do
    delta = choice["delta"] || %{}
    index = choice["index"]

    {tool_events, data} = tool_events(delta, index, term, config, data)
    {stop_events, data} = finish_events(choice["finish_reason"], term, config, data)
    {usage_events, data} = usage_events(term["usage"], term, config, data)

    events =
      text_events(delta, index, term, config) ++
        thinking_events(delta, index, term, config) ++
        tool_events ++
        stop_events ++
        usage_events ++
        unmapped_delta_events(delta, term, config)

    {events, data}
  end

  defp text_events(%{"content" => text}, index, term, config)
       when is_binary(text) and text != "" do
    [Helpers.event(:text_delta, index, %StreamDelta.Text{text: text}, term, config)]
  end

  defp text_events(_delta, _index, _term, _config), do: []

  defp thinking_events(%{"reasoning_content" => text}, index, term, config)
       when is_binary(text) and text != "" do
    [
      Helpers.event(
        :thinking_delta,
        index,
        %StreamDelta.Thinking{text: text, signature: nil},
        term,
        config
      )
    ]
  end

  defp thinking_events(_delta, _index, _term, _config), do: []

  defp unmapped_delta_events(delta, term, config) when is_map(delta) do
    unknown =
      for {key, value} <- delta, key not in @known_delta_keys, not is_nil(value), into: %{} do
        {key, value}
      end

    case map_size(unknown) do
      0 ->
        []

      _size ->
        [
          Helpers.event(
            :message_delta,
            nil,
            %StreamDelta.Raw{data: %{"data" => unknown}},
            term,
            config
          )
        ]
    end
  end

  defp unmapped_delta_events(_delta, _term, _config), do: []

  defp tool_events(%{"tool_calls" => calls}, index, term, config, data) when is_list(calls) do
    Enum.reduce(calls, {[], data}, fn call, {events, data} ->
      tool_index = call["index"] || index || 0
      function = call["function"] || %{}
      seen? = tool_index in data.tool_indexes
      data = %{data | tool_indexes: Enum.uniq([tool_index | data.tool_indexes])}

      {events ++ tool_call_events(call, function, tool_index, seen?, term, config), data}
    end)
  end

  defp tool_events(_delta, _index, _term, _config, data), do: {[], data}

  defp tool_call_events(call, function, tool_index, seen?, term, config) do
    delta = %StreamDelta.ToolCall{
      id: call["id"],
      name: function["name"],
      arguments: function["arguments"],
      index: tool_index
    }

    cond do
      not seen? ->
        [
          Helpers.event(:tool_call_start, tool_index, delta, term, config)
          | fragment_events(function["arguments"], tool_index, term, config)
        ]

      is_binary(function["arguments"]) and function["arguments"] != "" ->
        [Helpers.event(:tool_call_delta, tool_index, delta, term, config)]

      is_binary(call["id"]) or is_binary(function["name"]) ->
        [Helpers.event(:tool_call_start, tool_index, delta, term, config)]

      true ->
        []
    end
  end

  defp fragment_events(fragment, index, term, config)
       when is_binary(fragment) and fragment != "" do
    [
      Helpers.event(
        :tool_call_delta,
        index,
        %StreamDelta.ToolCall{arguments: fragment, index: index},
        term,
        config
      )
    ]
  end

  defp fragment_events(_fragment, _index, _term, _config), do: []

  defp finish_events(nil, _term, _config, data), do: {[], data}

  defp finish_events(finish_reason, term, config, data) do
    stops =
      data.tool_indexes
      |> Enum.sort()
      |> Enum.map(
        &Helpers.event(:tool_call_stop, &1, %StreamDelta.ToolCall{index: &1}, term, config)
      )

    delta = %StreamDelta.MessageDelta{stop_reason: stop_reason(finish_reason), usage: nil}

    {stops ++ [Helpers.event(:message_delta, nil, delta, term, config)],
     %{data | tool_indexes: []}}
  end

  defp usage_events(nil, _term, _config, data), do: {[], data}

  defp usage_events(usage, term, config, data) when is_map(usage) do
    merged = merge_usage(data.usage, usage)
    delta = %StreamDelta.MessageDelta{stop_reason: nil, usage: merged}
    {[Helpers.event(:message_delta, nil, delta, term, config)], %{data | usage: merged}}
  end

  defp usage_events(_usage, _term, _config, data), do: {[], data}

  defp usage_tail(term, config, data) do
    {usage_events, data} = usage_events(term["usage"], term, config, data)
    closed = %{data | finished?: true}
    {usage_events ++ [Helpers.event(:message_stop, nil, nil, term, config)], closed}
  end

  defp merge_usage(nil, wire), do: merge_usage(%Usage{}, wire)

  defp merge_usage(%Usage{} = current, wire) do
    %Usage{
      input_tokens: wire["prompt_tokens"] || current.input_tokens,
      output_tokens: wire["completion_tokens"] || current.output_tokens,
      total_tokens: wire["total_tokens"] || current.total_tokens,
      cache_read_tokens:
        get_in(wire, ["prompt_tokens_details", "cached_tokens"]) || current.cache_read_tokens,
      cache_write_tokens: current.cache_write_tokens,
      reasoning_tokens:
        get_in(wire, ["completion_tokens_details", "reasoning_tokens"]) ||
          current.reasoning_tokens
    }
  end

  defp raw_delta(term, config) do
    Helpers.event(:message_delta, nil, %StreamDelta.Raw{data: term}, term, config)
  end
end
