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

  alias LlmCall.{
    Config,
    Content,
    EncodedRequest,
    Error,
    Message,
    Reasoning,
    Request,
    Capabilities,
    ReasoningCapabilities,
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

  @path "/v1/chat/completions"
  @headers [{"content-type", "application/json"}]
  @reserved_keys ~w(model messages system contents tools stream)
  @param_keys [:temperature, :top_p, :max_tokens, :stop, :seed]
  @efforts [:none, :minimal, :low, :medium, :high]
  @retryable_codes ~w(rate_limit_exceeded rate_limit_error server_error overloaded_error timeout)
  @known_message_keys ["role", "content", "tool_calls", "reasoning_content", "refusal"]
  @known_delta_keys ["content", "reasoning_content", "tool_calls"]

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
  @spec encode_request(Request.t(), Config.t()) ::
          {:ok, EncodedRequest.t()} | {:error, Error.t()}
  def encode_request(%Request{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      {:ok,
       %EncodedRequest{
         method: :post,
         path: @path,
         query: %{},
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
         :ok <- validate_tools(request.tools, request.tool_choice),
         :ok <- validate_system(request.system),
         :ok <- validate_parts(request.messages),
         :ok <- validate_provider_options(request, config) do
      :ok
    end
  end

  defp body(request, config) do
    %{}
    |> Map.put("model", request.model)
    |> Map.put("messages", messages(request))
    |> maybe_put("tools", encode_tools(request.tools))
    |> maybe_put("tool_choice", encode_tool_choice(request.tool_choice))
    |> maybe_put("response_format", encode_response_format(request.output))
    |> maybe_put("reasoning_effort", encode_reasoning_effort(request.reasoning))
    |> Map.merge(encode_params(request.params))
    |> put_stream(request.stream)
    |> Map.merge(reasoning_provider_options(request.reasoning))
    |> Config.deep_merge(provider_options(request, config))
  end

  defp messages(request) do
    system_messages(request.system) ++
      Enum.flat_map(request.messages, &(&1 |> encode_message() |> List.wrap()))
  end

  defp system_messages(nil), do: []

  defp system_messages(text) when is_binary(text) do
    [%{"role" => "system", "content" => text}]
  end

  defp system_messages(parts) when is_list(parts) do
    [%{"role" => "system", "content" => Enum.map(parts, &encode_part/1)}]
  end

  defp encode_message(%Message{role: :user, content: content}) do
    {results, other_parts} = Enum.split_with(content, &is_struct(&1, ToolResult))

    tool_messages = Enum.map(results, &encode_tool_result/1)

    remaining =
      case other_parts do
        [] -> []
        parts -> [%{"role" => "user", "content" => Enum.map(parts, &encode_part/1)}]
      end

    tool_messages ++ remaining
  end

  defp encode_message(%Message{role: :assistant, content: content}) do
    calls = Enum.filter(content, &is_struct(&1, ToolCall))
    texts = Enum.filter(content, &is_struct(&1, Content.Text))

    text_content =
      case texts do
        [] -> nil
        parts -> Enum.map(parts, &encode_part/1)
      end

    message = %{"role" => "assistant", "content" => text_content}

    case calls do
      [] -> message
      calls -> Map.put(message, "tool_calls", Enum.map(calls, &encode_tool_call/1))
    end
  end

  defp encode_part(%Content.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_part(%Content.Image{source: source, media_type: media_type}) do
    %{"type" => "image_url", "image_url" => %{"url" => image_url(source, media_type)}}
  end

  defp image_url({:base64, data}, media_type), do: "data:#{media_type};base64,#{data}"
  defp image_url({:url, url}, _media_type), do: url
  defp image_url(url, _media_type) when is_binary(url), do: url

  defp encode_tool_call(%ToolCall{} = call) do
    %{
      "id" => call.id,
      "type" => "function",
      "function" => %{
        "name" => call.name,
        "arguments" => call.raw_arguments || LlmCall.JSON.encode(call.arguments || %{})
      }
    }
  end

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
        |> maybe_put("description", spec.description)
        |> maybe_put("parameters", spec.parameters)
        |> maybe_put("strict", spec.strict)
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
        |> maybe_put("strict", strict)
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

  defp validate_model(model) when is_binary(model) and model != "", do: :ok
  defp validate_model(_model), do: error("model is required")

  defp validate_messages([]), do: error("at least one message is required")

  defp validate_messages(messages) when is_list(messages) do
    first_error(messages, fn
      %Message{role: role} when role in [:user, :assistant] -> :ok
      %Message{} -> error("message role must be :user or :assistant")
      _other -> error("messages must be LlmCall.Message structs")
    end)
  end

  defp validate_params(params) when is_map(params) do
    first_error(Map.keys(params), fn key ->
      if key in @param_keys, do: :ok, else: error("params key #{inspect(key)} is not supported")
    end)
  end

  defp validate_params(_params), do: error("params must be a map")

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%Reasoning{} = reasoning) do
    with :ok <- validate_effort(reasoning.effort),
         :ok <- reject(reasoning.budget_tokens, "reasoning budget_tokens is not supported"),
         :ok <- reject(reasoning.summary, "reasoning summary is not supported") do
      :ok
    end
  end

  defp validate_reasoning(_reasoning), do: error("reasoning must be a LlmCall.Reasoning struct")

  defp validate_effort(nil), do: :ok

  defp validate_effort(effort) when effort in @efforts, do: :ok

  defp validate_effort(effort) do
    error("reasoning effort #{inspect(effort)} is not supported")
  end

  defp validate_tools(tools, tool_choice) when is_list(tools) do
    with :ok <- first_error(tools, &validate_tool_spec/1),
         :ok <- validate_tool_choice(tool_choice, tools) do
      :ok
    end
  end

  defp validate_tools(_tools, _tool_choice), do: error("tools must be a list")

  defp validate_tool_spec(%ToolSpec{kind: :builtin}) do
    error("builtin tools are not supported")
  end

  defp validate_tool_spec(%ToolSpec{name: name}) when is_binary(name) and name != "", do: :ok

  defp validate_tool_spec(%ToolSpec{}), do: error("function tool requires a name")
  defp validate_tool_spec(_spec), do: error("tools must be LlmCall.ToolSpec structs")

  defp validate_tool_choice(:auto, _tools), do: :ok
  defp validate_tool_choice(:none, _tools), do: :ok

  defp validate_tool_choice(choice, tools) when choice in [:required] or is_tuple(choice) do
    if tools == [] do
      error("tool_choice requires at least one tool")
    else
      validate_tool_choice_value(choice)
    end
  end

  defp validate_tool_choice(choice, _tools) do
    error("tool_choice #{inspect(choice)} is not supported")
  end

  defp validate_tool_choice_value(:required), do: :ok
  defp validate_tool_choice_value({:tool, name}) when is_binary(name) and name != "", do: :ok
  defp validate_tool_choice_value({:tool, _name}), do: error("tool_choice tool name is required")

  defp validate_tool_choice_value({:allowed, _names}),
    do: error("tool_choice {:allowed, names} is not supported")

  defp validate_tool_choice_value(choice),
    do: error("tool_choice #{inspect(choice)} is not supported")

  defp validate_system(nil), do: :ok
  defp validate_system(text) when is_binary(text), do: :ok
  defp validate_system(parts) when is_list(parts), do: first_error(parts, &validate_system_part/1)
  defp validate_system(_system), do: error("system must be a string or a list of content parts")

  defp validate_system_part(%Content.Text{text: text}) when is_binary(text), do: :ok
  defp validate_system_part(%Content.Text{}), do: error("system text part requires text")
  defp validate_system_part(_part), do: error("system only supports text parts")

  defp validate_parts(messages) do
    first_error(messages, fn %Message{role: role, content: content} ->
      with :ok <- validate_content_list(content) do
        first_error(content, &validate_part(role, &1))
      end
    end)
  end

  defp validate_content_list([]), do: error("message requires at least one content part")
  defp validate_content_list(content) when is_list(content), do: :ok

  defp validate_content_list(_content),
    do: error("message content must be a list of content parts")

  defp validate_part(:user, %ToolCall{}), do: error("tool calls belong to assistant messages")

  defp validate_part(:assistant, %ToolResult{}),
    do: error("tool results belong to user messages")

  defp validate_part(:assistant, %Content.Image{}),
    do: error("images belong to user messages")

  defp validate_part(_role, %Content.Text{}), do: :ok

  defp validate_part(_role, %Content.Image{source: {:base64, _data}, media_type: nil}),
    do: error("base64 image requires media_type")

  defp validate_part(_role, %Content.Image{source: {:base64, _data}}), do: :ok
  defp validate_part(_role, %Content.Image{source: {:url, _url}}), do: :ok
  defp validate_part(_role, %Content.Image{source: source}) when is_binary(source), do: :ok
  defp validate_part(_role, %Content.Image{}), do: error("image source is not supported")
  defp validate_part(_role, %Content.File{}), do: error("file content is not supported")

  defp validate_part(_role, %Content.Thinking{}),
    do: error("thinking content is not supported in a request")

  defp validate_part(_role, %Content.Raw{}),
    do: error("raw content is not supported in a request")

  defp validate_part(_role, %ToolCall{id: nil}), do: error("tool call requires an id")
  defp validate_part(_role, %ToolCall{name: nil}), do: error("tool call requires a name")
  defp validate_part(_role, %ToolCall{}), do: :ok
  defp validate_part(_role, %ToolResult{call_id: nil}), do: error("tool result requires call_id")

  defp validate_part(_role, %ToolResult{content: content}),
    do: validate_tool_result_content(content)

  defp validate_part(_role, _part), do: error("unsupported content part")

  defp validate_tool_result_content(content) when is_binary(content), do: :ok

  defp validate_tool_result_content(content) when is_list(content),
    do: first_error(content, &validate_tool_result_part/1)

  defp validate_tool_result_content(_content),
    do: error("tool result content must be a string or content parts")

  defp validate_tool_result_part(%Content.Text{}), do: :ok
  defp validate_tool_result_part(_part), do: error("tool result only supports text content")

  defp validate_provider_options(request, config) do
    case Map.get(Config.provider_options(request, config), :openai, %{}) do
      options when is_map(options) ->
        first_error(Map.keys(options), fn key ->
          if reserved_key?(key) do
            error("provider option #{inspect(key)} would replace a canonical field")
          else
            :ok
          end
        end)

      _options ->
        error("provider_options.openai must be a map")
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
    do: {:error, %Error{kind: :validation, message: "openai_chat: " <> message}}

  @impl true
  def decode_response(term, %Config{} = config) when is_map(term) do
    with {:ok, choice} <- first_choice(term),
         {:ok, message} <- fetch_message(choice) do
      {:ok,
       %Response{
         id: term["id"],
         model: term["model"],
         content: message_content(message) ++ extra_choices(term),
         stop_reason: stop_reason(choice["finish_reason"]),
         usage: decode_usage(term["usage"]),
         raw: capture_response(config, term)
       }}
    end
  end

  def decode_response(_term, _config) do
    {:error,
     %Error{kind: :invalid_response, message: "openai_chat: payload is not a JSON object"}}
  end

  @impl true
  def decode_error(%{"error" => %{"message" => message} = error} = payload, _config) do
    code = error["code"] || error["type"]

    %Error{
      kind: :provider,
      message: message,
      code: code,
      status: nil,
      retryable?: code in @retryable_codes,
      raw: payload
    }
  end

  def decode_error(_term, _config) do
    %Error{kind: :invalid_response, message: "openai_chat: unrecognized error payload", raw: nil}
  end

  @impl true
  def capabilities(%Request{}, _config) do
    %Capabilities{
      tools: true,
      parallel_tool_calls: true,
      tool_choice: true,
      structured_output: :json_schema,
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
         id: nil,
         model: nil,
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
    data = %{data | id: term["id"] || data.id, model: term["model"] || data.model}
    {events, data} = chunk_events(term, config, data)
    {:ok, events, StreamState.new(__MODULE__, data)}
  end

  def decode_stream_event(_term, _config, %StreamState{} = state), do: {:done, state}

  @impl true
  def finish_stream(%StreamState{} = state, %Config{} = config) do
    data = StreamState.data(state)

    if data.finished? do
      {:ok, [], state}
    else
      closed = %{data | finished?: true}
      {:ok, [event(:message_stop, nil, nil, nil, config)], StreamState.new(__MODULE__, closed)}
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

  defp message_content(message) do
    thinking =
      case message["reasoning_content"] do
        text when is_binary(text) and text != "" ->
          [%Content.Thinking{text: text, signature: nil}]

        _other ->
          []
      end

    text =
      case message["content"] do
        text when is_binary(text) and text != "" ->
          [%Content.Text{text: text}]

        value when not is_nil(value) and not is_binary(value) ->
          [%Content.Raw{type: "content", data: %{"content" => value}}]

        _other ->
          []
      end

    calls = Enum.map(message["tool_calls"] || [], &decode_tool_call/1)

    refusal =
      case message["refusal"] do
        text when is_binary(text) -> [%Content.Raw{type: "refusal", data: %{"refusal" => text}}]
        _other -> []
      end

    unknown =
      for {key, value} <- message,
          key not in @known_message_keys,
          not is_nil(value),
          do: %Content.Raw{type: key, data: %{key => value}}

    thinking ++ text ++ calls ++ refusal ++ unknown
  end

  defp decode_tool_call(entry) do
    function = entry["function"] || %{}
    raw = function["arguments"]
    {arguments, arguments_error} = decode_arguments(raw)

    %ToolCall{
      id: entry["id"],
      name: function["name"],
      arguments: arguments,
      raw_arguments: raw,
      arguments_error: arguments_error
    }
  end

  defp decode_arguments(nil), do: {nil, nil}

  defp decode_arguments(raw) when is_binary(raw) do
    case :json.decode(raw) do
      decoded when is_map(decoded) -> {decoded, nil}
      _not_a_map -> {nil, {:invalid_json, raw}}
    end
  rescue
    _decode_error -> {nil, {:invalid_json, raw}}
  end

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
    [event(:text_delta, index, %StreamDelta.Text{text: text}, term, config)]
  end

  defp text_events(_delta, _index, _term, _config), do: []

  defp thinking_events(%{"reasoning_content" => text}, index, term, config)
       when is_binary(text) and text != "" do
    [
      event(
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
        [event(:message_delta, nil, %StreamDelta.Raw{data: %{"data" => unknown}}, term, config)]
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
          event(:tool_call_start, tool_index, delta, term, config)
          | fragment_events(function["arguments"], tool_index, term, config)
        ]

      is_binary(function["arguments"]) and function["arguments"] != "" ->
        [event(:tool_call_delta, tool_index, delta, term, config)]

      is_binary(call["id"]) or is_binary(function["name"]) ->
        [event(:tool_call_start, tool_index, delta, term, config)]

      true ->
        []
    end
  end

  defp fragment_events(fragment, index, term, config)
       when is_binary(fragment) and fragment != "" do
    [
      event(
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
      |> Enum.map(&event(:tool_call_stop, &1, %StreamDelta.ToolCall{index: &1}, term, config))

    delta = %StreamDelta.MessageDelta{stop_reason: stop_reason(finish_reason), usage: nil}

    {stops ++ [event(:message_delta, nil, delta, term, config)], %{data | tool_indexes: []}}
  end

  defp usage_events(nil, _term, _config, data), do: {[], data}

  defp usage_events(usage, term, config, data) when is_map(usage) do
    merged = merge_usage(data.usage, usage)
    delta = %StreamDelta.MessageDelta{stop_reason: nil, usage: merged}
    {[event(:message_delta, nil, delta, term, config)], %{data | usage: merged}}
  end

  defp usage_events(_usage, _term, _config, data), do: {[], data}

  defp usage_tail(term, config, data) do
    {usage_events, data} = usage_events(term["usage"], term, config, data)
    closed = %{data | finished?: true}
    {usage_events ++ [event(:message_stop, nil, nil, term, config)], closed}
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
    event(:message_delta, nil, %StreamDelta.Raw{data: term}, term, config)
  end

  defp event(type, index, delta, term, config) do
    %StreamEvent{type: type, index: index, delta: delta, raw: capture_event(config, term)}
  end

  defp capture_event(%Config{capture_raw: :all}, term) when is_map(term), do: term
  defp capture_event(_config, _term), do: nil

  defp capture_response(%Config{capture_raw: raw}, term) when raw in [:response, :all], do: term
  defp capture_response(_config, _term), do: nil
end
