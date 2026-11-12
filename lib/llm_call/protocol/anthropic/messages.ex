defmodule LlmCall.Protocol.Anthropic.Messages do
  @moduledoc """
  Anthropic Messages (`POST /v1/messages`).

  `system` is a top-level field, `max_tokens` is required, tool results are
  `tool_result` blocks inside a user turn, and reasoning is controlled by an
  explicit thinking budget rather than an effort level.

  `call_id` on a tool result is the Anthropic `tool_use_id`.
  """

  alias LlmCall.{
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
    StreamEvent,
    StreamState,
    ToolCall,
    ToolResult,
    ToolSpec,
    Usage
  }

  alias LlmCall.StreamDelta

  @behaviour LlmCall.Codec

  @api_version "2023-06-01"
  @path "/v1/messages"
  @headers [{"content-type", "application/json"}, {"anthropic-version", @api_version}]
  @reserved_keys ~w(model messages system contents tools stream)
  @param_keys [:max_tokens, :temperature, :top_p, :top_k, :stop]
  @retryable_types ~w(overloaded_error rate_limit_error api_error timeout_error)

  @impl true
  @spec info() :: Codec.Info.t()
  def info do
    %Codec.Info{
      name: :anthropic_messages,
      protocol: :anthropic_messages,
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
         :ok <- validate_output(request.output),
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
    |> Map.put("messages", Enum.map(request.messages, &encode_message/1))
    |> maybe_put("system", encode_system(request.system))
    |> maybe_put("tools", encode_tools(request.tools))
    |> maybe_put("tool_choice", encode_tool_choice(request.tool_choice, request.tools))
    |> maybe_put("thinking", encode_reasoning(request.reasoning))
    |> Map.merge(encode_params(request.params))
    |> Map.merge(provider_options(request, config))
  end

  defp encode_system(nil), do: nil
  defp encode_system(text) when is_binary(text), do: text

  defp encode_system(parts) when is_list(parts) do
    Enum.map(parts, fn
      %Content.Text{text: text} -> %{"type" => "text", "text" => text}
      %Content.Raw{data: %{} = data} -> data
    end)
  end

  defp encode_message(%Message{role: role, content: content}) do
    %{"role" => Atom.to_string(role), "content" => Enum.map(content, &encode_part/1)}
  end

  defp encode_part(%Content.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_part(%Content.Thinking{text: text, signature: signature}) do
    %{"type" => "thinking", "thinking" => text, "signature" => signature}
  end

  defp encode_part(%Content.Image{source: source, media_type: media_type}) do
    %{"type" => "image", "source" => encode_source(source, media_type)}
  end

  defp encode_part(%Content.File{source: source, media_type: media_type, filename: filename}) do
    %{"type" => "document", "source" => encode_source(source, media_type)}
    |> maybe_put("title", filename)
  end

  defp encode_part(%ToolCall{} = call) do
    %{
      "type" => "tool_use",
      "id" => call.id,
      "name" => call.name,
      "input" => call.arguments || decode_raw_arguments(call) || %{}
    }
  end

  defp encode_part(%ToolResult{} = result) do
    %{
      "type" => "tool_result",
      "tool_use_id" => result.call_id,
      "content" => tool_result_content(result.content)
    }
    |> maybe_put("is_error", result.is_error || nil)
  end

  defp encode_part(%Content.Raw{data: %{} = data}), do: data

  defp encode_source({:base64, data}, media_type) do
    %{"type" => "base64", "media_type" => media_type, "data" => data}
  end

  defp encode_source({:url, url}, _media_type), do: %{"type" => "url", "url" => url}

  defp encode_source({:file_id, file_id}, _media_type),
    do: %{"type" => "file", "file_id" => file_id}

  defp encode_source(url, _media_type) when is_binary(url), do: %{"type" => "url", "url" => url}

  defp tool_result_content(content) when is_binary(content), do: content
  defp tool_result_content(parts) when is_list(parts), do: Enum.map(parts, &encode_part/1)

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
    Enum.map(specs, fn %ToolSpec{} = spec ->
      %{
        "name" => spec.name,
        "input_schema" => spec.parameters || %{"type" => "object", "properties" => %{}}
      }
      |> maybe_put("description", spec.description)
      |> Config.deep_merge(tool_options(spec))
    end)
  end

  defp tool_options(%ToolSpec{provider_options: options}) when is_map(options), do: options
  defp tool_options(_spec), do: %{}

  defp encode_tool_choice(_choice, []), do: nil
  defp encode_tool_choice(:auto, _tools), do: %{"type" => "auto"}
  defp encode_tool_choice(:none, _tools), do: %{"type" => "none"}
  defp encode_tool_choice(:required, _tools), do: %{"type" => "any"}
  defp encode_tool_choice({:tool, name}, _tools), do: %{"type" => "tool", "name" => name}

  defp encode_reasoning(nil), do: nil

  defp encode_reasoning(%Reasoning{} = reasoning) do
    base =
      cond do
        is_integer(reasoning.budget_tokens) ->
          %{"type" => "enabled", "budget_tokens" => reasoning.budget_tokens}

        reasoning.effort == :none ->
          %{"type" => "disabled"}

        true ->
          %{}
      end

    case Config.deep_merge(base, reasoning_options(reasoning)) do
      merged when map_size(merged) == 0 -> nil
      merged -> merged
    end
  end

  defp reasoning_options(%Reasoning{provider_options: options}) when is_map(options), do: options
  defp reasoning_options(_reasoning), do: %{}

  defp encode_params(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn
      {:stop, value} -> {"stop_sequences", value}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  defp provider_options(request, config) do
    Config.provider_options(request, config) |> Map.get(:anthropic, %{})
  end

  defp validate_model(model) when is_binary(model) and model != "", do: :ok
  defp validate_model(_model), do: error("model is required")

  defp validate_messages([]), do: error("at least one message is required")

  defp validate_messages(messages) when is_list(messages) do
    first_error(messages, fn
      %Message{role: role, content: []} when role in [:user, :assistant] ->
        error("message requires at least one content part")

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
    with :ok <- first_error(Map.keys(params), &validate_param_key/1) do
      case params[:max_tokens] do
        value when is_integer(value) and value > 0 -> :ok
        _other -> error("params.max_tokens is required and must be a positive integer")
      end
    end
  end

  defp validate_params(_params), do: error("params must be a map")

  defp validate_param_key(key) do
    if key in @param_keys, do: :ok, else: error("params key #{inspect(key)} is not supported")
  end

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%Reasoning{} = reasoning) do
    with :ok <- validate_effort(reasoning.effort),
         :ok <- validate_budget(reasoning.budget_tokens),
         :ok <- reject(reasoning.summary, "reasoning summary is not supported"),
         :ok <- reject_budget_with_effort(reasoning),
         :ok <- validate_options(reasoning.provider_options, "reasoning.provider_options") do
      :ok
    end
  end

  defp validate_reasoning(_reasoning), do: error("reasoning must be a LlmCall.Reasoning struct")

  defp validate_effort(nil), do: :ok
  defp validate_effort(:none), do: :ok

  defp validate_effort(effort) do
    error("reasoning effort #{inspect(effort)} is not supported; use budget_tokens")
  end

  defp validate_budget(nil), do: :ok

  defp validate_budget(budget) when is_integer(budget) and budget > 0,
    do: :ok

  defp validate_budget(_budget), do: error("reasoning budget_tokens must be a positive integer")

  defp reject_budget_with_effort(%Reasoning{budget_tokens: budget, effort: effort})
       when not is_nil(budget) and not is_nil(effort) do
    error("reasoning budget_tokens and effort cannot be combined")
  end

  defp reject_budget_with_effort(%Reasoning{}), do: :ok

  defp validate_output(:text), do: :ok

  defp validate_output(output) do
    error("output #{inspect(output)} is not supported")
  end

  defp validate_tools(tools, tool_choice) when is_list(tools) do
    with :ok <- first_error(tools, &validate_tool_spec/1),
         :ok <- validate_tool_choice(tool_choice, tools) do
      :ok
    end
  end

  defp validate_tools(_tools, _tool_choice), do: error("tools must be a list")

  defp validate_tool_spec(%ToolSpec{kind: :builtin}), do: error("builtin tools are not supported")

  defp validate_tool_spec(%ToolSpec{name: name} = spec) when is_binary(name) and name != "" do
    with :ok <- reject(spec.strict, "tool strict mode is not supported"),
         :ok <- validate_options(spec.provider_options, "tool provider_options") do
      :ok
    end
  end

  defp validate_tool_spec(%ToolSpec{}), do: error("function tool requires a name")
  defp validate_tool_spec(_spec), do: error("tools must be LlmCall.ToolSpec structs")

  defp validate_options(options, _label) when is_map(options), do: :ok
  defp validate_options(_options, label), do: error("#{label} must be a map")

  defp validate_tool_choice(:auto, _tools), do: :ok
  defp validate_tool_choice(:none, _tools), do: :ok
  defp validate_tool_choice(:required, []), do: error("tool_choice requires at least one tool")
  defp validate_tool_choice(:required, _tools), do: :ok

  defp validate_tool_choice({:allowed, _names}, _tools),
    do: error("tool_choice {:allowed, names} is not supported")

  defp validate_tool_choice({:tool, name}, []) when is_binary(name),
    do: error("tool_choice requires at least one tool")

  defp validate_tool_choice({:tool, name}, _tools) when is_binary(name) and name != "", do: :ok

  defp validate_tool_choice({:tool, _name}, _tools),
    do: error("tool_choice tool name is required")

  defp validate_tool_choice(choice, _tools),
    do: error("tool_choice #{inspect(choice)} is not supported")

  defp validate_system(nil), do: :ok
  defp validate_system(text) when is_binary(text), do: :ok
  defp validate_system(parts) when is_list(parts), do: first_error(parts, &validate_system_part/1)
  defp validate_system(_system), do: error("system must be a string or a list of content parts")

  defp validate_system_part(%Content.Text{text: text}) when is_binary(text), do: :ok
  defp validate_system_part(%Content.Text{}), do: error("system text part requires text")
  defp validate_system_part(%Content.Raw{data: %{}}), do: :ok
  defp validate_system_part(_part), do: error("system only supports text parts")

  defp validate_parts(messages) do
    first_error(messages, fn %Message{role: role, content: content} ->
      first_error(content, &validate_part(role, &1))
    end)
  end

  defp validate_part(:user, %ToolCall{}), do: error("tool calls belong to assistant messages")

  defp validate_part(:user, %Content.Thinking{}),
    do: error("thinking blocks belong to assistant messages")

  defp validate_part(:assistant, %ToolResult{}),
    do: error("tool results belong to user messages")

  defp validate_part(_role, %Content.Text{}), do: :ok

  defp validate_part(_role, %Content.Thinking{signature: nil}) do
    error("thinking content requires a signature")
  end

  defp validate_part(_role, %Content.Thinking{}), do: :ok

  defp validate_part(_role, %Content.Image{source: {:file_id, _file_id}}),
    do: error("image source {:file_id, id} is not supported")

  defp validate_part(_role, %Content.Image{source: {:base64, _data}, media_type: nil}),
    do: error("base64 image requires media_type")

  defp validate_part(_role, %Content.Image{source: {:base64, _data}}), do: :ok
  defp validate_part(_role, %Content.Image{source: {:url, _url}}), do: :ok
  defp validate_part(_role, %Content.Image{source: source}) when is_binary(source), do: :ok
  defp validate_part(_role, %Content.Image{}), do: error("image source is not supported")

  defp validate_part(_role, %Content.File{source: {:base64, _data}, media_type: nil}),
    do: error("base64 document requires media_type")

  defp validate_part(_role, %Content.File{}), do: :ok
  defp validate_part(_role, %Content.Raw{data: %{}}), do: :ok
  defp validate_part(_role, %Content.Raw{}), do: error("raw content requires a map payload")
  defp validate_part(_role, %ToolCall{id: nil}), do: error("tool call requires an id")
  defp validate_part(_role, %ToolCall{name: nil}), do: error("tool call requires a name")
  defp validate_part(_role, %ToolCall{} = call), do: validate_tool_call_arguments(call)
  defp validate_part(_role, %ToolResult{call_id: nil}), do: error("tool result requires call_id")

  defp validate_part(_role, %ToolResult{content: content}),
    do: validate_tool_result_content(content)

  defp validate_part(_role, _part), do: error("unsupported content part")

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
    case Map.get(Config.provider_options(request, config), :anthropic, %{}) do
      options when is_map(options) ->
        first_error(Map.keys(options), fn key ->
          if reserved_key?(key) do
            error("provider option #{inspect(key)} would replace a canonical field")
          else
            :ok
          end
        end)

      _options ->
        error("provider_options.anthropic must be a map")
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
    do: {:error, %Error{kind: :validation, message: "anthropic_messages: " <> message}}

  @impl true
  def decode_response(term, %Config{} = config) when is_map(term) do
    with {:ok, blocks} <- fetch_blocks(term) do
      {:ok,
       %Response{
         id: term["id"],
         model: term["model"],
         content: Enum.map(blocks, &decode_block/1),
         stop_reason: stop_reason(term["stop_reason"]),
         usage: decode_usage(term["usage"]),
         raw: capture_response(config, term)
       }}
    end
  end

  def decode_response(_term, _config) do
    {:error, invalid_response("payload is not a JSON object")}
  end

  @impl true
  def decode_error(%{"error" => %{"message" => message} = error} = payload, _config) do
    type = error["type"]

    %Error{
      kind: :provider,
      message: message,
      code: type,
      status: nil,
      retryable?: type in @retryable_types,
      raw: payload
    }
  end

  def decode_error(_term, _config) do
    %Error{
      kind: :invalid_response,
      message: "anthropic_messages: unrecognized error payload",
      raw: nil
    }
  end

  @impl true
  def capabilities(%Request{}, _config) do
    %Capabilities{
      tools: true,
      parallel_tool_calls: true,
      tool_choice: true,
      structured_output: :none,
      image_input: true,
      file_input: true,
      reasoning: %ReasoningCapabilities{
        supported: true,
        efforts: [],
        default_effort: nil,
        budget_tokens: true,
        adaptive: true,
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
         blocks: %{},
         pending_tools: [],
         usage: %Usage{},
         finished?: false
       })}
    end
  end

  @impl true
  def decode_stream_event(
        %{"type" => "error", "error" => error},
        %Config{} = config,
        %StreamState{}
      ) do
    {:error, decode_error(%{"error" => error}, config)}
  end

  def decode_stream_event(term, %Config{} = config, %StreamState{} = state) when is_map(term) do
    data = StreamState.data(state)
    {events, data} = stream_events(term, config, data)
    {:ok, events, StreamState.new(__MODULE__, data)}
  end

  def decode_stream_event(_term, _config, %StreamState{} = state), do: {:ok, [], state}

  @impl true
  def finish_stream(%StreamState{} = state, _config), do: {:ok, [], state}

  defp fetch_blocks(%{"content" => blocks}) when is_list(blocks), do: {:ok, blocks}
  defp fetch_blocks(_term), do: {:error, invalid_response("response has no content blocks")}

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "anthropic_messages: " <> message}
  end

  defp decode_block(%{"type" => "text"} = block) do
    %Content.Text{text: block["text"]}
  end

  defp decode_block(%{"type" => "thinking"} = block) do
    %Content.Thinking{text: block["thinking"], signature: block["signature"]}
  end

  defp decode_block(%{"type" => "tool_use"} = block) do
    %ToolCall{
      id: block["id"],
      name: block["name"],
      arguments: block["input"],
      raw_arguments: nil,
      arguments_error: nil
    }
  end

  defp decode_block(block) when is_map(block) do
    %Content.Raw{type: block["type"], data: block}
  end

  defp stop_reason("end_turn"), do: :end_turn
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason("stop_sequence"), do: :stop_sequence
  defp stop_reason("tool_use"), do: :tool_calls
  defp stop_reason("refusal"), do: :content_filter
  defp stop_reason(_other), do: :unknown

  defp decode_usage(nil), do: nil
  defp decode_usage(%{} = usage), do: merge_usage(%Usage{}, usage)
  defp decode_usage(_usage), do: nil

  defp merge_usage(%Usage{} = current, wire) when is_map(wire) do
    input = wire["input_tokens"] || current.input_tokens
    output = wire["output_tokens"] || current.output_tokens

    %Usage{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total_tokens(input, output),
      cache_read_tokens: wire["cache_read_input_tokens"] || current.cache_read_tokens,
      cache_write_tokens: wire["cache_creation_input_tokens"] || current.cache_write_tokens,
      reasoning_tokens: current.reasoning_tokens
    }
  end

  defp merge_usage(%Usage{} = current, _wire), do: current

  defp total_tokens(nil, _output), do: nil
  defp total_tokens(_input, nil), do: nil
  defp total_tokens(input, output), do: input + output

  defp stream_events(%{"type" => "message_start"} = term, config, data) do
    message = term["message"] || %{}

    data = %{
      data
      | id: message["id"] || data.id,
        model: message["model"] || data.model,
        usage: merge_usage(data.usage, message["usage"])
    }

    {[event(:message_start, nil, nil, term, config)], data}
  end

  defp stream_events(%{"type" => "content_block_start"} = term, config, data) do
    index = term["index"]
    block = term["content_block"] || %{}

    case block["type"] do
      "tool_use" ->
        delta = %StreamDelta.ToolCall{
          id: block["id"],
          name: block["name"],
          arguments: nil,
          index: index
        }

        {[event(:tool_call_start, index, delta, term, config)],
         record_block(data, index, :tool_use)}

      type ->
        {[event(:content_start, index, nil, term, config)],
         record_block(data, index, block_type(type))}
    end
  end

  defp stream_events(%{"type" => "content_block_delta"} = term, config, data) do
    block_delta(term, config, data)
  end

  defp stream_events(%{"type" => "content_block_stop"} = term, config, data) do
    index = term["index"]

    case Map.get(data.blocks, index) do
      :tool_use ->
        delta = %StreamDelta.ToolCall{index: index}

        {[event(:tool_call_stop, index, delta, term, config)],
         %{data | pending_tools: List.delete(data.pending_tools, index)}}

      _other ->
        {[event(:content_stop, index, nil, term, config)], data}
    end
  end

  defp stream_events(%{"type" => "message_delta"} = term, config, data) do
    message_delta = term["delta"] || %{}
    data = %{data | usage: merge_usage(data.usage, term["usage"])}

    reason =
      case message_delta["stop_reason"] do
        nil -> nil
        wire -> stop_reason(wire)
      end

    delta = %StreamDelta.MessageDelta{stop_reason: reason, usage: data.usage}
    {[event(:message_delta, nil, delta, term, config)], data}
  end

  defp stream_events(%{"type" => "message_stop"} = term, config, data) do
    {[event(:message_stop, nil, nil, term, config)], %{data | finished?: true}}
  end

  defp stream_events(%{"type" => "ping"}, _config, data), do: {[], data}

  defp stream_events(term, config, data) do
    {[event(:message_delta, nil, %StreamDelta.Raw{data: term}, term, config)], data}
  end

  defp block_delta(term, config, data) do
    index = term["index"]
    delta = term["delta"] || %{}

    case delta["type"] do
      "text_delta" ->
        {[event(:text_delta, index, %StreamDelta.Text{text: delta["text"]}, term, config)], data}

      "input_json_delta" ->
        tool_delta = %StreamDelta.ToolCall{arguments: delta["partial_json"], index: index}
        {[event(:tool_call_delta, index, tool_delta, term, config)], data}

      "thinking_delta" ->
        thinking = %StreamDelta.Thinking{text: delta["thinking"], signature: nil}
        {[event(:thinking_delta, index, thinking, term, config)], data}

      "signature_delta" ->
        thinking = %StreamDelta.Thinking{text: "", signature: delta["signature"]}
        {[event(:thinking_delta, index, thinking, term, config)], data}

      _other ->
        raw = %StreamDelta.Raw{data: %{"data" => delta}}
        {[event(:message_delta, nil, raw, term, config)], data}
    end
  end

  defp record_block(data, index, type) do
    data = %{data | blocks: Map.put(data.blocks, index, type)}

    if type == :tool_use do
      %{data | pending_tools: Enum.uniq([index | data.pending_tools])}
    else
      data
    end
  end

  defp block_type("text"), do: :text
  defp block_type("thinking"), do: :thinking
  defp block_type(_type), do: :other

  defp event(type, index, delta, term, config) do
    %StreamEvent{type: type, index: index, delta: delta, raw: capture_event(config, term)}
  end

  defp capture_event(%Config{capture_raw: :all}, term) when is_map(term), do: term
  defp capture_event(_config, _term), do: nil

  defp capture_response(%Config{capture_raw: raw}, term) when raw in [:response, :all], do: term
  defp capture_response(_config, _term), do: nil
end
