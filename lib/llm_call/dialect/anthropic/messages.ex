defmodule LlmCall.Dialect.Anthropic.Messages do
  @moduledoc """
  Anthropic Messages (`POST /v1/messages`).

  `system` is a top-level field, `max_tokens` is required, tool results are
  `tool_result` blocks inside a user turn, and reasoning is controlled by an
  explicit thinking budget rather than an effort level.

  `call_id` on a tool result is the Anthropic `tool_use_id`.
  """

  @api_version "2023-06-01"
  @path "/v1/messages"
  @headers [{"content-type", "application/json"}, {"anthropic-version", @api_version}]
  @envelope_keys ~w(model messages system tools thinking stream)
  @default_reserved_keys @envelope_keys ++
                           ~w(tool_choice max_tokens temperature top_p top_k stop_sequences)
  @tool_reserved_keys ~w(name description input_schema)
  @builtin_tools :passthrough
  @reasoning_reserved_keys ~w(type budget_tokens)
  @param_keys [:max_tokens, :temperature, :top_p, :top_k, :stop]
  @retryable_types ~w(overloaded_error rate_limit_error api_error timeout_error)

  @namespaces [:anthropic]

  @native_options %{
    "metadata" => :map,
    "service_tier" => :string,
    "container" => :string,
    "mcp_servers" => :list,
    "context_management" => :map
  }

  use LlmCall.Dialect.Adapter, codec: :anthropic_messages

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
  @spec validate_request(Request.t(), Config.t()) :: :ok | {:error, Error.t()}
  def validate_request(%Request{} = request, %Config{} = config) do
    with :ok <- validate_model(request.model),
         :ok <- Helpers.validate_modalities(request.modalities, [:text], @codec),
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
         :ok <- validate_parts(request.messages, config.json) do
      validate_provider_options(request, config)
    end
  end

  defp body(request, config) do
    body =
      %{}
      |> Map.put("model", request.model)
      |> Map.put("messages", Enum.map(request.messages, &encode_message(&1, config.json)))
      |> Helpers.maybe_put("system", encode_system(request.system))
      |> Helpers.maybe_put("tools", encode_tools(request.tools))
      |> Helpers.maybe_put("tool_choice", encode_tool_choice(request.tool_choice, request.tools))
      |> Helpers.maybe_put("thinking", encode_reasoning(request.reasoning))
      |> Map.merge(encode_params(request.params))
      |> Helpers.maybe_put("stream", encode_stream(request.stream))
      |> Config.deep_merge(provider_options(request, config))

    {:ok, body}
  end

  defp encode_stream(true), do: true
  defp encode_stream(false), do: nil

  defp encode_system(nil), do: nil
  defp encode_system([]), do: nil
  defp encode_system(text) when is_binary(text), do: text

  defp encode_system(parts) when is_list(parts) do
    Enum.map(parts, fn %Content.Text{text: text} -> %{"type" => "text", "text" => text} end)
  end

  defp encode_message(%Message{role: role, content: content}, json) do
    %{"role" => Atom.to_string(role), "content" => Enum.map(content, &encode_part(&1, json))}
  end

  defp encode_part(%Content.Text{text: text}, _json), do: %{"type" => "text", "text" => text}

  defp encode_part(%Content.Thinking{text: text, signature: signature}, _json) do
    %{"type" => "thinking", "thinking" => text, "signature" => signature}
  end

  defp encode_part(%Content.Image{source: source, media_type: media_type}, _json) do
    %{"type" => "image", "source" => encode_source(source, media_type)}
  end

  defp encode_part(
         %Content.File{source: source, media_type: media_type, filename: filename},
         _json
       ) do
    %{"type" => "document", "source" => encode_source(source, media_type)}
    |> Helpers.maybe_put("title", filename)
  end

  defp encode_part(%ToolCall{} = call, json) do
    %{
      "type" => "tool_use",
      "id" => call.id,
      "name" => call.name,
      "input" => call.arguments || Helpers.decode_raw_arguments(call.raw_arguments, json) || %{}
    }
  end

  defp encode_part(%ToolResult{} = result, json) do
    %{
      "type" => "tool_result",
      "tool_use_id" => result.call_id,
      "content" => tool_result_content(result.content, json)
    }
    |> Helpers.maybe_put("is_error", result.is_error || nil)
  end

  defp encode_part(%Content.Raw{data: %{} = data}, _json), do: data

  defp encode_source({:base64, data}, media_type) do
    %{"type" => "base64", "media_type" => media_type, "data" => data}
  end

  defp encode_source({:url, url}, _media_type), do: %{"type" => "url", "url" => url}

  defp encode_source({:file_id, file_id}, _media_type),
    do: %{"type" => "file", "file_id" => file_id}

  defp encode_source(url, _media_type) when is_binary(url), do: %{"type" => "url", "url" => url}

  defp tool_result_content(content, _json) when is_binary(content), do: content

  defp tool_result_content(parts, json) when is_list(parts),
    do: Enum.map(parts, &encode_part(&1, json))

  defp encode_tools([]), do: nil

  defp encode_tools(specs) do
    Enum.map(specs, fn
      %ToolSpec{kind: :builtin} = spec ->
        %{"type" => spec.name} |> Config.deep_merge(tool_options(spec))

      %ToolSpec{} = spec ->
        %{
          "name" => spec.name,
          "input_schema" => spec.parameters || %{"type" => "object", "properties" => %{}}
        }
        |> Helpers.maybe_put("description", spec.description)
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

  defp validate_model(model), do: Helpers.validate_model(model, @codec)

  defp validate_messages(messages), do: Helpers.validate_messages(messages, @codec)

  defp validate_params(params) when is_map(params) do
    with :ok <- Helpers.validate_params(params, @param_keys, @codec) do
      validate_max_tokens(params[:max_tokens])
    end
  end

  defp validate_params(_params), do: Helpers.error(@codec, "params must be a map")

  defp validate_max_tokens(value) when is_integer(value) and value > 0, do: :ok

  defp validate_max_tokens(_value) do
    Helpers.error(@codec, "params.max_tokens is required and must be a positive integer")
  end

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%Reasoning{} = reasoning) do
    with :ok <- validate_effort(reasoning.effort),
         :ok <- validate_budget(reasoning.budget_tokens),
         :ok <- Helpers.reject(reasoning.summary, @codec, "reasoning summary is not supported"),
         :ok <- reject_budget_with_effort(reasoning) do
      with :ok <-
             Helpers.validate_options(
               reasoning.provider_options,
               @codec,
               "reasoning.provider_options"
             ) do
        Helpers.validate_option_keys(
          reasoning.provider_options,
          @reasoning_reserved_keys,
          @codec
        )
      end
    end
  end

  defp validate_reasoning(_reasoning),
    do: Helpers.error(@codec, "reasoning must be a LlmCall.Reasoning struct")

  defp validate_effort(nil), do: :ok
  defp validate_effort(:none), do: :ok

  defp validate_effort(effort) do
    Helpers.error(
      @codec,
      "reasoning effort #{inspect(effort)} is not supported; use budget_tokens"
    )
  end

  defp validate_budget(nil), do: :ok

  defp validate_budget(budget) when is_integer(budget) and budget > 0,
    do: :ok

  defp validate_budget(_budget),
    do: Helpers.error(@codec, "reasoning budget_tokens must be a positive integer")

  defp reject_budget_with_effort(%Reasoning{budget_tokens: budget, effort: effort})
       when not is_nil(budget) and not is_nil(effort) do
    Helpers.error(@codec, "reasoning budget_tokens and effort cannot be combined")
  end

  defp reject_budget_with_effort(%Reasoning{}), do: :ok

  defp validate_output(:text), do: :ok

  defp validate_output(output) do
    Helpers.error(@codec, "output #{inspect(output)} is not supported")
  end

  defp validate_native_tool_choice(%{"tool_choice" => choice}) when is_map(choice) do
    Helpers.validate_option_keys(choice, ["type", "name"], @codec)
  end

  defp validate_native_tool_choice(%{"tool_choice" => _other}) do
    Helpers.error(@codec, "provider_options.tool_choice must be a map")
  end

  defp validate_native_tool_choice(_options), do: :ok

  defp validate_tool_spec(%ToolSpec{kind: :builtin} = spec) do
    with :ok <-
           Helpers.validate_tool_spec(spec, @codec,
             options: true,
             builtin_tools: @builtin_tools
           ) do
      Helpers.validate_option_keys(spec.provider_options, ["type"], @codec)
    end
  end

  defp validate_tool_spec(spec) do
    with :ok <-
           Helpers.validate_tool_spec(spec, @codec,
             options: true,
             builtin_tools: @builtin_tools
           ) do
      Helpers.validate_option_keys(spec.provider_options, @tool_reserved_keys, @codec)
    end
  end

  defp validate_tool_choice(:auto, _tools), do: :ok
  defp validate_tool_choice(:none, _tools), do: :ok

  defp validate_tool_choice(:required, []),
    do: Helpers.error(@codec, "tool_choice requires at least one tool")

  defp validate_tool_choice(:required, _tools), do: :ok

  defp validate_tool_choice({:allowed, _names}, _tools),
    do: Helpers.error(@codec, "tool_choice {:allowed, names} is not supported")

  defp validate_tool_choice({:tool, name}, []) when is_binary(name),
    do: Helpers.error(@codec, "tool_choice requires at least one tool")

  defp validate_tool_choice({:tool, name}, _tools) when is_binary(name) and name != "", do: :ok

  defp validate_tool_choice({:tool, _name}, _tools),
    do: Helpers.error(@codec, "tool_choice tool name is required")

  defp validate_tool_choice(choice, _tools),
    do: Helpers.error(@codec, "tool_choice #{inspect(choice)} is not supported")

  defp validate_parts(messages, json),
    do: Helpers.validate_parts(messages, @codec, &validate_part_shape(&1, &2, json))

  defp validate_part_shape(_role, %Content.Text{}, _json), do: :ok

  defp validate_part_shape(_role, %Content.Thinking{signature: nil}, _json) do
    Helpers.error(@codec, "thinking content requires a signature")
  end

  defp validate_part_shape(_role, %Content.Thinking{}, _json), do: :ok

  defp validate_part_shape(_role, %Content.Image{source: {:file_id, _file_id}}, _json),
    do: Helpers.error(@codec, "image source {:file_id, id} is not supported")

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

  defp validate_part_shape(
         _role,
         %Content.File{source: {:base64, _data}, media_type: nil},
         _json
       ),
       do: Helpers.error(@codec, "base64 document requires media_type")

  defp validate_part_shape(_role, %Content.File{}, _json), do: :ok
  defp validate_part_shape(_role, %Content.Raw{data: %{}}, _json), do: :ok

  defp validate_part_shape(_role, %Content.Raw{}, _json),
    do: Helpers.error(@codec, "raw content requires a map payload")

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
         request_options = Map.get(request.provider_options, :anthropic, %{}),
         default_options = Map.get(config.default_provider_options, :anthropic, %{}),
         :ok <- Helpers.validate_option_keys(request_options, @envelope_keys, @codec),
         :ok <-
           Helpers.validate_native_options(
             request_options,
             @native_options,
             @codec,
             "provider_options"
           ) do
      with :ok <- Helpers.validate_option_keys(default_options, @default_reserved_keys, @codec),
           :ok <-
             Helpers.validate_native_options(
               default_options,
               @native_options,
               @codec,
               "default_provider_options"
             ) do
        validate_native_tool_choice(request_options)
      end
    end
  end

  @impl true
  def decode_response(term, %Config{} = config) when is_map(term) do
    with {:ok, blocks} <- fetch_blocks(term),
         {:ok, content} <- decode_blocks(blocks) do
      {:ok,
       %Response{
         id: term["id"],
         model: term["model"],
         content: content,
         stop_reason: stop_reason(term["stop_reason"]),
         usage: decode_usage(term["usage"]),
         raw: Helpers.capture_response(config, term)
       }}
    end
  end

  def decode_response(_term, _config) do
    {:error, invalid_response("payload is not a JSON object")}
  end

  @impl true
  def decode_error(payload, _config) do
    Helpers.decode_provider_error(payload, @codec, ["type"], @retryable_types)
  end

  @impl true
  def capabilities(%Request{}, _config) do
    %Capabilities{
      tools: true,
      builtin_tools: @builtin_tools,
      parallel_tool_calls: true,
      tool_choice: true,
      structured_output: :none,
      modalities: [:text],
      image_input: true,
      file_input: true,
      reasoning: %ReasoningCapabilities{
        supported: true,
        efforts: [:none],
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
    with :ok <- validate_stream_chunk(term) do
      data = StreamState.data(state)
      {events, data} = stream_events(term, config, data)
      {:ok, events, StreamState.new(__MODULE__, data)}
    end
  end

  def decode_stream_event(_term, _config, %StreamState{} = state), do: {:ok, [], state}

  defp validate_stream_chunk(%{"type" => "message_start", "message" => message})
       when not is_nil(message) and not is_map(message),
       do: {:error, invalid_response("message_start message must be an object")}

  defp validate_stream_chunk(%{"type" => "content_block_start", "content_block" => block})
       when not is_nil(block) and not is_map(block),
       do: {:error, invalid_response("content_block_start content_block must be an object")}

  defp validate_stream_chunk(%{"type" => "content_block_delta", "delta" => delta})
       when not is_nil(delta) and not is_map(delta),
       do: {:error, invalid_response("content_block_delta delta must be an object")}

  defp validate_stream_chunk(%{"type" => "content_block_delta", "delta" => delta})
       when is_map(delta),
       do: validate_delta(delta)

  defp validate_stream_chunk(%{"type" => "message_delta", "delta" => delta})
       when not is_nil(delta) and not is_map(delta),
       do: {:error, invalid_response("message_delta delta must be an object")}

  defp validate_stream_chunk(_term), do: :ok

  defp validate_delta(%{"type" => "text_delta", "text" => text}) when is_binary(text), do: :ok

  defp validate_delta(%{"type" => "text_delta"}),
    do: {:error, invalid_response("text_delta text must be a string")}

  defp validate_delta(%{"type" => "thinking_delta", "thinking" => text})
       when is_binary(text),
       do: :ok

  defp validate_delta(%{"type" => "thinking_delta"}),
    do: {:error, invalid_response("thinking_delta thinking must be a string")}

  defp validate_delta(%{"type" => "signature_delta", "signature" => signature})
       when is_binary(signature),
       do: :ok

  defp validate_delta(%{"type" => "signature_delta"}),
    do: {:error, invalid_response("signature_delta signature must be a string")}

  defp validate_delta(%{"type" => "input_json_delta", "partial_json" => fragment})
       when is_binary(fragment),
       do: :ok

  defp validate_delta(%{"type" => "input_json_delta"}),
    do: {:error, invalid_response("input_json_delta partial_json must be a string")}

  defp validate_delta(_delta), do: :ok

  @impl true
  def finish_stream(%StreamState{} = state, _config), do: {:ok, [], state}

  defp fetch_blocks(%{"content" => blocks}) when is_list(blocks), do: {:ok, blocks}
  defp fetch_blocks(_term), do: {:error, invalid_response("response has no content blocks")}

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "anthropic_messages: " <> message}
  end

  defp decode_block(%{"type" => "text", "text" => text}) when is_binary(text) do
    %Content.Text{text: text}
  end

  defp decode_block(%{"type" => "thinking", "thinking" => text} = block)
       when is_binary(text) do
    case block["signature"] do
      nil ->
        %Content.Thinking{text: text, signature: nil}

      signature when is_binary(signature) ->
        %Content.Thinking{text: text, signature: signature}

      _other ->
        %Content.Raw{type: "thinking", data: block}
    end
  end

  defp decode_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input})
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(input) do
    %ToolCall{
      id: id,
      name: name,
      arguments: input,
      raw_arguments: nil,
      arguments_error: nil
    }
  end

  defp decode_block(block) when is_map(block) do
    %Content.Raw{type: block["type"], data: block}
  end

  defp decode_block(_block), do: :error

  defp decode_blocks(blocks) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case decode_block(block) do
        :error ->
          {:halt, {:error, invalid_response("content block is not an object")}}

        part ->
          {:cont, {:ok, [part | acc]}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
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
    input = Helpers.token(wire["input_tokens"]) || current.input_tokens
    output = Helpers.token(wire["output_tokens"]) || current.output_tokens

    %Usage{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total_tokens(input, output),
      cache_read_tokens:
        Helpers.token(wire["cache_read_input_tokens"]) || current.cache_read_tokens,
      cache_write_tokens:
        Helpers.token(wire["cache_creation_input_tokens"]) || current.cache_write_tokens,
      reasoning_tokens: current.reasoning_tokens
    }
  end

  defp merge_usage(%Usage{} = current, _wire), do: current

  defp total_tokens(nil, _output), do: nil
  defp total_tokens(_input, nil), do: nil

  defp total_tokens(input, output) when is_integer(input) and is_integer(output),
    do: input + output

  defp total_tokens(_input, _output), do: nil

  defp stream_events(%{"type" => "message_start"} = term, config, data) do
    message = term["message"] || %{}
    data = %{data | usage: merge_usage(data.usage, message["usage"])}

    {[Helpers.event(:message_start, nil, nil, term, config)], data}
  end

  defp stream_events(%{"type" => "content_block_start"} = term, config, data) do
    index = Helpers.index(term["index"])
    block = term["content_block"] || %{}

    case block["type"] do
      "tool_use" ->
        delta = %StreamDelta.ToolCall{
          id: block["id"],
          name: block["name"],
          arguments: nil,
          index: index
        }

        {[Helpers.event(:tool_call_start, index, delta, term, config)],
         record_block(data, index, :tool_use)}

      type ->
        {[Helpers.event(:content_start, index, nil, term, config)],
         record_block(data, index, block_type(type))}
    end
  end

  defp stream_events(%{"type" => "content_block_delta"} = term, config, data) do
    block_delta(term, config, data)
  end

  defp stream_events(%{"type" => "content_block_stop"} = term, config, data) do
    index = Helpers.index(term["index"])

    case Map.get(data.blocks, index) do
      :tool_use ->
        delta = %StreamDelta.ToolCall{index: index}

        {[Helpers.event(:tool_call_stop, index, delta, term, config)],
         %{data | pending_tools: List.delete(data.pending_tools, index)}}

      _other ->
        {[Helpers.event(:content_stop, index, nil, term, config)], data}
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
    {[Helpers.event(:message_delta, nil, delta, term, config)], data}
  end

  defp stream_events(%{"type" => "message_stop"} = term, config, data) do
    {[Helpers.event(:message_stop, nil, nil, term, config)], %{data | finished?: true}}
  end

  defp stream_events(%{"type" => "ping"}, _config, data), do: {[], data}

  defp stream_events(term, config, data) do
    {[Helpers.event(:message_delta, nil, %StreamDelta.Raw{data: term}, term, config)], data}
  end

  defp block_delta(term, config, data) do
    index = Helpers.index(term["index"])
    delta = term["delta"] || %{}

    case delta["type"] do
      "text_delta" ->
        {[
           Helpers.event(:text_delta, index, %StreamDelta.Text{text: delta["text"]}, term, config)
         ], data}

      "input_json_delta" ->
        tool_delta = %StreamDelta.ToolCall{arguments: delta["partial_json"], index: index}
        {[Helpers.event(:tool_call_delta, index, tool_delta, term, config)], data}

      "thinking_delta" ->
        thinking = %StreamDelta.Thinking{text: delta["thinking"], signature: nil}
        {[Helpers.event(:thinking_delta, index, thinking, term, config)], data}

      "signature_delta" ->
        thinking = %StreamDelta.Thinking{text: "", signature: delta["signature"]}
        {[Helpers.event(:thinking_delta, index, thinking, term, config)], data}

      _other ->
        raw = %StreamDelta.Raw{data: %{"data" => delta}}
        {[Helpers.event(:message_delta, nil, raw, term, config)], data}
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
end
