defmodule LlmCall.Dialect.OpenAI.Responses do
  @moduledoc """
  OpenAI Responses (`POST /v1/responses`).

  Responses is a separate protocol from Chat Completions, not an endpoint
  toggle. A request is a list of typed `input` items; a response is a list of
  typed `output` items. System instructions move to `instructions`, tool results
  become `function_call_output` items, and server-side state is expressed with
  `store` and `previous_response_id` in `provider_options`.

  Streaming uses semantic `response.*` events rather than delta chunks, and has
  no `[DONE]` sentinel: the stream ends after `response.completed`,
  `response.failed`, `response.incomplete`, or `error`.

  For a persistent WebSocket connection with `stream_id` lanes, see
  `LlmCall.Dialect.OpenAI.Responses.Connection`.

  Reasoning items are decoded as `Content.Thinking`, with `encrypted_content`
  kept in `signature`. Replaying a reasoning item is not supported: a canonical
  `Content.Thinking` carries no item id, so sending it as input is a validation
  error rather than a silently dropped item.

  An assistant turn goes back as an easy-input message — `{"type": "message",
  "role": "assistant", "content": [{"type": "input_text", …}]}` — because the
  alternative shape, the original output item, requires the item `id` and `status`
  that a canonical `Message` does not carry.

  `text` is a reserved envelope key, since `format` is derived from `output`; the
  documented `text.verbosity` knob is therefore not reachable from
  `provider_options`. A tool's `parameters` and `strict` are only sent when set.
  """

  @path "/v1/responses"
  @headers [{"content-type", "application/json"}]

  @envelope_keys ~w(model input instructions tools tool_choice text reasoning stream)

  @default_reserved_keys @envelope_keys ++ ~w(max_output_tokens temperature top_p)

  @tool_reserved_keys ~w(name description parameters strict)
  @reasoning_reserved_keys ~w(effort summary)

  @native_options %{
    "access_programs" => :map,
    "store" => :boolean,
    "previous_response_id" => :string,
    "include" => :list,
    "parallel_tool_calls" => :boolean,
    "truncation" => {:enum, ["auto", "disabled"]},
    "background" => :boolean,
    "service_tier" => :string,
    "safety_identifier" => :string,
    "prompt_cache_key" => :string
  }
  @builtin_tools :passthrough
  @param_keys [:max_tokens, :temperature, :top_p]
  @param_spec %{
    max_tokens: {:integer, 1, :infinity},
    temperature: {:number, 0, 2},
    top_p: {:number, 0, 1}
  }
  @efforts [:none, :minimal, :low, :medium, :high, :xhigh, :max]
  @summaries [:auto, :concise, :detailed]
  @retryable_codes ~w(rate_limit_exceeded server_error overloaded_error timeout)
  @namespaces [:openai]

  use LlmCall.Dialect.Adapter, codec: :openai_responses

  @doc "The path used by both the HTTP and WebSocket transports."
  @spec path() :: String.t()
  def path, do: @path

  @impl true
  @spec info() :: LlmCall.Codec.Info.t()
  def info do
    %LlmCall.Codec.Info{
      name: :openai_responses,
      protocol: :openai_responses,
      version: nil,
      ir_version: 1
    }
  end

  @impl true
  @spec validate_request(Request.t(), Config.t()) :: :ok | {:error, Error.t()}
  def validate_request(%Request{} = request, %Config{} = config) do
    with :ok <- validate_model(request.model),
         :ok <- Helpers.validate_modalities(request.modalities, [:text], @codec),
         :ok <- Helpers.validate_messages(request.messages, @codec),
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
    with {:ok, input} <- input_items(request, config.json) do
      body =
        %{"model" => request.model, "input" => input}
        |> Helpers.maybe_put("instructions", instructions(request.system))
        |> Helpers.maybe_put("tools", encode_tools(request.tools))
        |> Helpers.maybe_put("tool_choice", encode_tool_choice(request.tool_choice))
        |> Helpers.maybe_put("text", encode_text(request.output))
        |> Helpers.maybe_put("reasoning", encode_reasoning(request.reasoning))
        |> Map.merge(encode_params(request.params))
        |> put_stream(request.stream)
        |> Config.deep_merge(provider_options(request, config))

      {:ok, body}
    end
  end

  defp instructions(nil), do: nil
  defp instructions([]), do: nil
  defp instructions(text) when is_binary(text), do: text
  defp instructions(parts) when is_list(parts), do: Enum.map_join(parts, "\n", & &1.text)

  defp input_items(request, json) do
    with {:ok, groups} <- Helpers.map_ok(request.messages, &encode_message(&1, json)) do
      {:ok, List.flatten(groups)}
    end
  end

  defp encode_message(%Message{role: :user, content: content}, json) do
    {results, other_parts} = Enum.split_with(content, &is_struct(&1, ToolResult))

    with {:ok, outputs} <- Helpers.map_ok(results, &encode_tool_result/1),
         {:ok, parts} <- Helpers.map_ok(other_parts, &encode_input_part(&1, json)) do
      message = message_item("user", parts)
      {:ok, outputs ++ message}
    end
  end

  defp encode_message(%Message{role: :assistant, content: content}, json) do
    calls = Enum.filter(content, &is_struct(&1, ToolCall))
    texts = Enum.filter(content, &is_struct(&1, Content.Text))

    with {:ok, encoded_calls} <- Helpers.map_ok(calls, &encode_function_call(&1, json)),
         {:ok, parts} <- Helpers.map_ok(texts, &encode_assistant_part/1) do
      {:ok, message_item("assistant", parts) ++ encoded_calls}
    end
  end

  defp message_item(_role, []), do: []

  defp message_item(role, parts) do
    [%{"type" => "message", "role" => role, "content" => parts}]
  end

  defp encode_input_part(%Content.Text{text: text}, _json) do
    {:ok, %{"type" => "input_text", "text" => text}}
  end

  defp encode_input_part(%Content.Image{source: source, media_type: media_type}, _json) do
    {:ok, encode_image_part(source, media_type)}
  end

  defp encode_input_part(%Content.File{} = file, _json) do
    {:ok, encode_file_part(file)}
  end

  defp encode_assistant_part(%Content.Text{text: text}),
    do: {:ok, %{"type" => "input_text", "text" => text}}

  defp encode_image_part({:base64, data}, media_type) do
    %{"type" => "input_image", "image_url" => "data:#{media_type};base64,#{data}"}
  end

  defp encode_image_part({:url, url}, _media_type),
    do: %{"type" => "input_image", "image_url" => url}

  defp encode_image_part({:file_id, id}, _media_type),
    do: %{"type" => "input_image", "file_id" => id}

  defp encode_image_part(url, _media_type) when is_binary(url),
    do: %{"type" => "input_image", "image_url" => url}

  defp encode_file_part(%Content.File{source: {:base64, data}, media_type: media_type} = file) do
    %{"type" => "input_file", "file_data" => "data:#{media_type};base64,#{data}"}
    |> Helpers.maybe_put("filename", file.filename)
  end

  defp encode_file_part(%Content.File{source: {:file_id, id}} = file) do
    %{"type" => "input_file", "file_id" => id}
    |> Helpers.maybe_put("filename", file.filename)
  end

  defp encode_file_part(%Content.File{source: {:url, url}} = file) do
    %{"type" => "input_file", "file_url" => url}
    |> Helpers.maybe_put("filename", file.filename)
  end

  defp encode_file_part(%Content.File{source: source} = file) when is_binary(source) do
    %{"type" => "input_file", "file_url" => source}
    |> Helpers.maybe_put("filename", file.filename)
  end

  defp encode_function_call(%ToolCall{} = call, json) do
    with {:ok, arguments} <- encode_call_arguments(call, json) do
      {:ok,
       %{
         "type" => "function_call",
         "call_id" => call.id,
         "name" => call.name,
         "arguments" => arguments
       }}
    end
  end

  defp encode_call_arguments(call, json), do: Helpers.encode_call_arguments(call, @codec, json)

  defp encode_tool_result(%ToolResult{} = result) do
    {:ok,
     %{
       "type" => "function_call_output",
       "call_id" => result.call_id,
       "output" => tool_result_output(result.content)
     }}
  end

  defp tool_result_output(content) when is_binary(content), do: content

  defp tool_result_output(parts) when is_list(parts) do
    Enum.map(parts, &%{"type" => "input_text", "text" => &1.text})
  end

  defp encode_tools([]), do: nil

  defp encode_tools(specs) do
    Enum.map(specs, fn
      %ToolSpec{kind: :builtin} = spec ->
        %{"type" => spec.name} |> Config.deep_merge(tool_options(spec))

      %ToolSpec{} = spec ->
        %{"type" => "function", "name" => spec.name}
        |> Helpers.maybe_put("description", spec.description)
        |> Helpers.maybe_put("parameters", spec.parameters)
        |> Helpers.maybe_put("strict", spec.strict)
        |> Config.deep_merge(tool_options(spec))
    end)
  end

  defp tool_options(%ToolSpec{provider_options: options}) when is_map(options), do: options
  defp tool_options(_spec), do: %{}

  defp encode_tool_choice(:auto), do: nil
  defp encode_tool_choice(:none), do: "none"
  defp encode_tool_choice(:required), do: "required"
  defp encode_tool_choice({:tool, name}), do: %{"type" => "function", "name" => name}

  defp encode_text(:text), do: nil
  defp encode_text(:json_object), do: %{"format" => %{"type" => "json_object"}}

  defp encode_text({:json_schema, name, schema, strict}) do
    %{
      "format" =>
        %{"type" => "json_schema", "name" => name, "schema" => schema}
        |> Helpers.maybe_put("strict", strict)
    }
  end

  defp encode_reasoning(nil), do: nil

  defp encode_reasoning(%Reasoning{} = reasoning) do
    encoded =
      %{}
      |> Helpers.maybe_put("effort", encode_effort(reasoning.effort))
      |> Helpers.maybe_put("summary", encode_summary(reasoning.summary))
      |> Config.deep_merge(reasoning_options(reasoning))

    if map_size(encoded) == 0, do: nil, else: encoded
  end

  defp encode_effort(nil), do: nil
  defp encode_effort(effort), do: Atom.to_string(effort)

  defp encode_summary(nil), do: nil
  defp encode_summary(summary), do: Atom.to_string(summary)

  defp reasoning_options(%Reasoning{provider_options: options}) when is_map(options),
    do: options

  defp reasoning_options(_reasoning), do: %{}

  defp encode_params(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn
      {:max_tokens, value} -> {"max_output_tokens", value}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  defp put_stream(body, false), do: body
  defp put_stream(body, true), do: Map.put(body, "stream", true)

  defp provider_options(request, config) do
    Config.provider_options(request, config) |> Map.get(:openai, %{})
  end

  defp validate_model(model), do: Helpers.validate_model(model, @codec)

  defp validate_params(params),
    do: Helpers.validate_params_with_spec(params, @param_keys, @param_spec, @codec)

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
             @reasoning_reserved_keys,
             @codec
           ) do
      validate_summary(reasoning.summary)
    end
  end

  defp validate_reasoning(_reasoning),
    do: Helpers.error(@codec, "reasoning must be a LlmCall.Reasoning struct")

  defp validate_effort(effort), do: Helpers.validate_effort(effort, @efforts, @codec)

  defp validate_summary(nil), do: :ok

  defp validate_summary(summary) when summary in @summaries, do: :ok

  defp validate_summary(summary) do
    Helpers.error(@codec, "reasoning summary #{inspect(summary)} is not supported")
  end

  defp validate_tool_spec(%ToolSpec{kind: :builtin} = spec) do
    Helpers.validate_tool_spec(spec, @codec, options: true, builtin_tools: @builtin_tools)
  end

  defp validate_tool_spec(spec) do
    with :ok <-
           Helpers.validate_tool_spec(spec, @codec,
             options: true,
             strict: true,
             builtin_tools: @builtin_tools
           ) do
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

  defp validate_part(role, part, json) do
    with :ok <- Helpers.validate_role(role, part, @codec) do
      validate_part_shape(role, part, json)
    end
  end

  defp validate_part_shape(:user, %Content.Text{}, _json), do: :ok

  defp validate_part_shape(:user, %Content.Image{source: source, media_type: media_type}, _json),
    do: validate_image(source, media_type)

  defp validate_part_shape(:user, %Content.File{source: source, media_type: media_type}, _json),
    do: validate_file(source, media_type)

  defp validate_part_shape(:user, %ToolResult{call_id: nil}, _json),
    do: Helpers.error(@codec, "tool result requires call_id")

  defp validate_part_shape(:user, %ToolResult{content: content}, _json),
    do: Helpers.validate_tool_result_content(content, @codec)

  defp validate_part_shape(:assistant, %Content.Text{}, _json), do: :ok

  defp validate_part_shape(:assistant, %Content.Image{}, _json),
    do: Helpers.error(@codec, "images belong to user messages")

  defp validate_part_shape(:assistant, %Content.File{}, _json),
    do: Helpers.error(@codec, "files belong to user messages")

  defp validate_part_shape(:assistant, %Content.Thinking{}, _json),
    do: Helpers.error(@codec, "reasoning items cannot be replayed in a request")

  defp validate_part_shape(:assistant, %ToolCall{id: nil}, _json),
    do: Helpers.error(@codec, "tool call requires a call_id")

  defp validate_part_shape(:assistant, %ToolCall{name: nil}, _json),
    do: Helpers.error(@codec, "tool call requires a name")

  defp validate_part_shape(:assistant, %ToolCall{} = call, json),
    do: Helpers.validate_tool_call_arguments(call, @codec, json)

  defp validate_part_shape(_role, %Content.Raw{}, _json),
    do: Helpers.error(@codec, "raw content is not supported in a request")

  defp validate_part_shape(_role, _part, _json),
    do: Helpers.error(@codec, "unsupported content part")

  defp validate_image({:base64, _data}, nil),
    do: Helpers.error(@codec, "base64 image requires media_type")

  defp validate_image({:base64, _data}, media_type) when is_binary(media_type), do: :ok
  defp validate_image({:file_id, _id}, _media_type), do: :ok
  defp validate_image({:url, _url}, _media_type), do: :ok
  defp validate_image(url, _media_type) when is_binary(url), do: :ok

  defp validate_image(_source, _media_type),
    do: Helpers.error(@codec, "image source is not supported")

  defp validate_file({:base64, _data}, nil),
    do: Helpers.error(@codec, "base64 file requires media_type")

  defp validate_file({:base64, _data}, media_type) when is_binary(media_type), do: :ok
  defp validate_file({:file_id, _id}, _media_type), do: :ok
  defp validate_file({:url, _url}, _media_type), do: :ok
  defp validate_file(url, _media_type) when is_binary(url), do: :ok

  defp validate_file(_source, _media_type),
    do: Helpers.error(@codec, "file source is not supported")

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
         :ok <-
           Helpers.validate_native_options(
             request_options,
             @native_options,
             @codec,
             "provider_options"
           ) do
      with :ok <- Helpers.validate_option_keys(default_options, @default_reserved_keys, @codec) do
        Helpers.validate_native_options(
          default_options,
          @native_options,
          @codec,
          "default_provider_options"
        )
      end
    end
  end

  @impl true
  def decode_response(%{} = term, %Config{} = config) do
    case term["status"] do
      "failed" ->
        {:error, failed_error(term, config)}

      _status ->
        with {:ok, content} <- decode_output(term["output"], config) do
          {:ok,
           %Response{
             id: term["id"],
             model: term["model"],
             content: content,
             stop_reason: response_stop_reason(term, content, :end_turn),
             usage: decode_usage(term["usage"]),
             raw: Helpers.capture_response(config, term)
           }}
        end
    end
  end

  def decode_response(_term, _config) do
    {:error, invalid_response("payload is not a JSON object")}
  end

  @impl true
  def decode_error(payload, %Config{} = config) do
    Helpers.decode_provider_error(payload, config, @codec, ["code", "type"], @retryable_codes)
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
      file_input: true,
      reasoning: %ReasoningCapabilities{
        supported: true,
        efforts: @efforts,
        default_effort: nil,
        budget_tokens: false,
        adaptive: false,
        summary: @summaries
      },
      streaming_tool_calls: true,
      prompt_cache: true,
      stateful: true,
      streaming: true
    }
  end

  @impl true
  def init_stream(%Request{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      {:ok,
       StreamState.new(__MODULE__, %{
         usage: nil,
         blocks: %{},
         pending_tools: [],
         tool_call?: false,
         finished?: false
       })}
    end
  end

  @impl true
  def decode_stream_event(
        %{"type" => "response.created"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    {:ok, [Helpers.event(:message_start, nil, nil, term, config)], state}
  end

  def decode_stream_event(%{"type" => "response.in_progress"}, %Config{}, %StreamState{} = state) do
    {:ok, [], state}
  end

  def decode_stream_event(
        %{"type" => "response.output_item.added"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    data = StreamState.data(state)
    item = map_or_empty(term["item"])
    index = Helpers.index(term["output_index"])

    case item["type"] do
      "function_call" ->
        delta = %StreamDelta.ToolCall{
          id: item["call_id"],
          name: item["name"],
          arguments: nil,
          index: index
        }

        data = %{
          data
          | blocks: Map.put(data.blocks, index, :function_call),
            pending_tools: Enum.uniq([index | data.pending_tools]),
            tool_call?: true
        }

        {:ok, [Helpers.event(:tool_call_start, index, delta, term, config)],
         StreamState.new(__MODULE__, data)}

      type ->
        {:ok, [],
         StreamState.new(__MODULE__, %{data | blocks: Map.put(data.blocks, index, type)})}
    end
  end

  def decode_stream_event(
        %{"type" => "response.content_part.added"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    data = StreamState.data(state)
    index = Helpers.index(term["output_index"])
    part = map_or_empty(term["part"])
    type = part["type"] || "unknown"
    data = %{data | blocks: Map.put(data.blocks, index, type)}

    {:ok, [Helpers.event(:content_start, index, nil, term, config)],
     StreamState.new(__MODULE__, data)}
  end

  def decode_stream_event(
        %{"type" => "response.output_text.delta"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    index = Helpers.index(term["output_index"])

    case term["delta"] do
      text when is_binary(text) ->
        delta = %StreamDelta.Text{text: text}
        {:ok, [Helpers.event(:text_delta, index, delta, term, config)], state}

      other ->
        {:error, invalid_response("text delta is not a string: #{inspect(other)}")}
    end
  end

  def decode_stream_event(
        %{"type" => "response.output_text.done"},
        %Config{},
        %StreamState{} = state
      ) do
    {:ok, [], state}
  end

  def decode_stream_event(
        %{"type" => "response.content_part.done"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    index = Helpers.index(term["output_index"])
    {:ok, [Helpers.event(:content_stop, index, nil, term, config)], state}
  end

  def decode_stream_event(
        %{"type" => "response.function_call_arguments.delta"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    index = Helpers.index(term["output_index"])

    case term["delta"] do
      text when is_binary(text) ->
        delta = %StreamDelta.ToolCall{arguments: text, index: index}
        {:ok, [Helpers.event(:tool_call_delta, index, delta, term, config)], state}

      other ->
        {:error, invalid_response("function arguments delta is not a string: #{inspect(other)}")}
    end
  end

  def decode_stream_event(
        %{"type" => "response.function_call_arguments.done"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    data = StreamState.data(state)
    index = Helpers.index(term["output_index"])

    delta = %StreamDelta.ToolCall{
      id: term["call_id"],
      name: term["name"],
      arguments: term["arguments"],
      index: index
    }

    data = %{data | pending_tools: List.delete(data.pending_tools, index)}

    {:ok, [Helpers.event(:tool_call_stop, index, delta, term, config)],
     StreamState.new(__MODULE__, data)}
  end

  def decode_stream_event(
        %{"type" => "response.output_item.done"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    data = StreamState.data(state)
    item = map_or_empty(term["item"])
    index = Helpers.index(term["output_index"])

    if item["type"] == "function_call" and index in data.pending_tools do
      delta = %StreamDelta.ToolCall{
        id: item["call_id"],
        name: item["name"],
        arguments: item["arguments"],
        index: index
      }

      data = %{data | pending_tools: List.delete(data.pending_tools, index)}

      {:ok, [Helpers.event(:tool_call_stop, index, delta, term, config)],
       StreamState.new(__MODULE__, data)}
    else
      {:ok, [], state}
    end
  end

  def decode_stream_event(
        %{"type" => "response.reasoning_summary_text.delta"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    case term["delta"] do
      text when is_binary(text) ->
        delta = %StreamDelta.Thinking{text: text, signature: nil}

        {:ok,
         [
           Helpers.event(
             :thinking_delta,
             Helpers.index(term["output_index"]),
             delta,
             term,
             config
           )
         ], state}

      other ->
        {:error, invalid_response("reasoning delta is not a string: #{inspect(other)}")}
    end
  end

  def decode_stream_event(
        %{"type" => "response.reasoning_text.delta"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    delta = %StreamDelta.Thinking{text: term["delta"], signature: nil}

    {:ok,
     [Helpers.event(:thinking_delta, Helpers.index(term["output_index"]), delta, term, config)],
     state}
  end

  def decode_stream_event(
        %{"type" => "response.reasoning_summary_part.added"},
        %Config{},
        %StreamState{} = state
      ) do
    {:ok, [], state}
  end

  def decode_stream_event(
        %{"type" => "response.reasoning_summary_part.done"},
        %Config{},
        %StreamState{} = state
      ) do
    {:ok, [], state}
  end

  def decode_stream_event(
        %{"type" => "response.completed"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    finalize_stream(term, config, state, :end_turn)
  end

  def decode_stream_event(
        %{"type" => "response.incomplete"} = term,
        %Config{} = config,
        %StreamState{} = state
      ) do
    finalize_stream(term, config, state, :unknown)
  end

  def decode_stream_event(
        %{"type" => "response.failed"} = term,
        %Config{} = config,
        %StreamState{}
      ) do
    {:error, failed_error(term["response"] || term, config)}
  end

  def decode_stream_event(%{"type" => "error"} = term, %Config{} = config, %StreamState{}) do
    {:error, stream_error(term, config)}
  end

  def decode_stream_event(term, %Config{} = config, %StreamState{} = state)
      when is_map(term) do
    {:ok, [Helpers.event(:message_delta, nil, %StreamDelta.Raw{data: term}, term, config)], state}
  end

  def decode_stream_event(term, _config, _state) do
    {:error, invalid_response("stream event is not an object: #{inspect(term)}")}
  end

  @impl true
  def finish_stream(%StreamState{} = state, %Config{} = config) do
    data = StreamState.data(state)

    if data.finished? do
      {:ok, [], state}
    else
      data = %{data | finished?: true}

      {:ok, [Helpers.event(:message_stop, nil, nil, nil, config)],
       StreamState.new(__MODULE__, data)}
    end
  end

  defp finalize_stream(term, config, state, default_reason) do
    data = StreamState.data(state)
    response = map_or_empty(term["response"])
    usage = merge_usage(data.usage, response["usage"])

    reason =
      if data.tool_call?,
        do: :tool_calls,
        else: response_stop_reason(response, [], default_reason)

    delta = %StreamDelta.MessageDelta{stop_reason: reason, usage: usage}
    data = %{data | usage: usage, finished?: true}

    {:ok,
     [
       Helpers.event(:message_delta, nil, delta, term, config),
       Helpers.event(:message_stop, nil, nil, term, config)
     ], StreamState.new(__MODULE__, data)}
  end

  defp decode_output(items, config) when is_list(items) do
    with {:ok, groups} <- Helpers.map_ok(items, &decode_output_item(&1, config)) do
      {:ok, List.flatten(groups)}
    end
  end

  defp decode_output(_items, _config),
    do: {:error, invalid_response("response has no output list")}

  defp decode_output_item(%{"type" => "message"} = item, _config),
    do: decode_message_item(item)

  defp decode_output_item(%{"type" => "function_call"} = item, config),
    do: decode_function_call(item, config)

  defp decode_output_item(%{"type" => "reasoning"} = item, _config),
    do: decode_reasoning_item(item)

  defp decode_output_item(%{"type" => type} = item, _config) when is_binary(type),
    do: {:ok, [%Content.Raw{type: type, data: item}]}

  defp decode_output_item(item, _config),
    do: {:error, invalid_response("output item has no type: #{inspect(item)}")}

  defp decode_message_item(%{"content" => content}) when is_list(content) do
    with {:ok, groups} <- Helpers.map_ok(content, &decode_message_part/1) do
      {:ok, List.flatten(groups)}
    end
  end

  defp decode_message_item(_item),
    do: {:error, invalid_response("message item has no content list")}

  defp decode_message_part(%{"type" => "output_text", "text" => text} = part)
       when is_binary(text) do
    annotations =
      for annotation <- annotations(part), is_map(annotation) do
        %Content.Raw{type: "annotation", data: annotation}
      end

    {:ok, [%Content.Text{text: text} | annotations]}
  end

  defp decode_message_part(%{"type" => "refusal"} = part),
    do: {:ok, [%Content.Raw{type: "refusal", data: part}]}

  defp decode_message_part(%{"type" => type} = part) when is_binary(type),
    do: {:ok, [%Content.Raw{type: type, data: part}]}

  defp decode_message_part(part),
    do: {:error, invalid_response("message content part is not an object: #{inspect(part)}")}

  defp annotations(%{"annotations" => annotations}) when is_list(annotations), do: annotations
  defp annotations(_part), do: []

  defp decode_function_call(%{"call_id" => call_id} = item, config) do
    raw = item["arguments"]
    {arguments, arguments_error} = decode_arguments(raw, config.json)

    {:ok,
     [
       %ToolCall{
         id: call_id,
         name: item["name"],
         arguments: arguments,
         raw_arguments: raw,
         arguments_error: arguments_error
       }
     ]}
  end

  defp decode_function_call(item, _config),
    do: {:error, invalid_response("function call has no call_id: #{inspect(item)}")}

  defp decode_reasoning_item(item) do
    case reasoning_text(item) do
      nil ->
        {:ok, [%Content.Raw{type: "reasoning", data: item}]}

      text ->
        {:ok, [%Content.Thinking{text: text, signature: item["encrypted_content"]}]}
    end
  end

  defp reasoning_text(%{"summary" => summary}) when is_list(summary) do
    text =
      summary
      |> Enum.filter(&(is_map(&1) and is_binary(&1["text"])))
      |> Enum.map_join("\n", & &1["text"])

    if text == "", do: nil, else: text
  end

  defp reasoning_text(%{"content" => content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&(is_map(&1) and is_binary(&1["text"])))
      |> Enum.map_join("\n", & &1["text"])

    if text == "", do: nil, else: text
  end

  defp reasoning_text(_item), do: nil

  defp decode_arguments(raw, json), do: Helpers.decode_arguments(raw, json)

  defp response_stop_reason(term, content, default) do
    cond do
      Enum.any?(content, &match?(%ToolCall{}, &1)) -> :tool_calls
      term["status"] == "incomplete" -> incomplete_reason(term)
      term["status"] == "completed" -> default
      term["status"] == "failed" -> :error
      true -> :unknown
    end
  end

  defp incomplete_reason(%{"incomplete_details" => %{"reason" => "max_output_tokens"}}),
    do: :max_tokens

  defp incomplete_reason(%{"incomplete_details" => %{"reason" => "content_filter"}}),
    do: :content_filter

  defp incomplete_reason(_term), do: :unknown

  defp decode_usage(nil), do: nil
  defp decode_usage(%{} = usage), do: merge_usage(nil, usage)
  defp decode_usage(_usage), do: nil

  defp merge_usage(current, nil), do: current

  defp merge_usage(current, %{} = wire) do
    base = current || %Usage{}

    %Usage{
      input_tokens: Helpers.token(wire["input_tokens"]) || base.input_tokens,
      output_tokens: Helpers.token(wire["output_tokens"]) || base.output_tokens,
      total_tokens: Helpers.token(wire["total_tokens"]) || base.total_tokens,
      cache_read_tokens:
        Helpers.token(Helpers.nested(wire, ["input_tokens_details", "cached_tokens"])) ||
          base.cache_read_tokens,
      cache_write_tokens:
        Helpers.token(Helpers.nested(wire, ["input_tokens_details", "cache_write_tokens"])) ||
          base.cache_write_tokens,
      reasoning_tokens:
        Helpers.token(Helpers.nested(wire, ["output_tokens_details", "reasoning_tokens"])) ||
          base.reasoning_tokens
    }
  end

  defp merge_usage(current, _wire), do: current

  defp failed_error(%{"error" => %{} = error} = response, %Config{} = config) do
    error_from(error, response, config)
  end

  defp failed_error(response, %Config{} = config) when is_map(response) do
    %Error{
      kind: :provider,
      message: "response failed",
      retryable?: false,
      raw: Helpers.capture_response(config, response)
    }
  end

  defp failed_error(_response, %Config{}) do
    %Error{kind: :provider, message: "response failed", retryable?: false}
  end

  defp stream_error(%{"error" => %{} = error} = event, %Config{} = config),
    do: error_from(error, event, config)

  defp stream_error(event, %Config{} = config) do
    %Error{
      kind: :provider,
      message: event["message"] || "stream error",
      code: Helpers.code(event["code"]) || event["type"],
      retryable?: Helpers.retryable?(event["code"], @retryable_codes),
      raw: Helpers.capture_response(config, event)
    }
  end

  defp error_from(%{} = error, %{} = raw, %Config{} = config) do
    %Error{
      kind: :provider,
      message: error["message"] || "response failed",
      code: Helpers.code(error["code"]) || error["type"],
      retryable?: Helpers.retryable?(error["code"], @retryable_codes),
      raw: Helpers.capture_response(config, raw)
    }
  end

  defp map_or_empty(%{} = value), do: value
  defp map_or_empty(_value), do: %{}

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "openai_responses: " <> message}
  end
end
