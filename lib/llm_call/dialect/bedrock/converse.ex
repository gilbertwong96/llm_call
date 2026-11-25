defmodule LlmCall.Dialect.Bedrock.Converse do
  @moduledoc """
  Bedrock's `Converse` API (`POST /model/{modelId}/converse`).

  One request shape covers every model Bedrock serves, which is why it is the
  dialect worth implementing first: `anthropic_version` and each vendor's own
  envelope disappear behind `messages`, `system` and `inferenceConfig`.

  A model ID is **one** path segment. Bedrock IDs carry `:` and inference-profile
  ARNs carry `/`, so the ID is percent-encoded here and signed verbatim by the
  transport.

  This phase carries text and tool use. Images and documents are refused rather
  than dropped: Converse takes them inline (`bytes`) or from S3 and has no URL
  source, and a capability flag that said `true` would promise a shape the codec
  must reject.
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

  @impl true
  def info do
    %Codec.Info{name: @codec, protocol: :bedrock_converse, version: @version, ir_version: 1}
  end

  @impl true
  def validate_request(%Request{} = request, %Config{} = config) do
    with :ok <- validate_model(request.model),
         :ok <- validate_unsupported(request),
         :ok <- validate_system(request.system),
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
         path: "/model/" <> encode_model(request.model) <> "/converse",
         headers: [{"content-type", "application/json"}],
         body: body(request, config)
       }}
    end
  end

  @impl true
  def capabilities(%Request{}, _config) do
    %Capabilities{
      tools: true,
      tool_choice: true,
      structured_output: :none,
      modalities: [:text],
      image_input: false,
      file_input: false,
      streaming: false,
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
      total_tokens: Helpers.token(usage["totalTokens"])
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

  defp validate_parts(messages), do: Helpers.validate_parts(messages, @codec, &validate_part/2)

  defp validate_part(_role, %Content.Text{}), do: :ok
  defp validate_part(_role, %ToolCall{}), do: :ok
  defp validate_part(_role, %ToolResult{}), do: :ok

  defp validate_part(_role, %Content.Image{}),
    do: Helpers.error(@codec, "Content.Image parts are not supported")

  defp validate_part(_role, %Content.File{}),
    do: Helpers.error(@codec, "Content.File parts are not supported")

  defp validate_part(_role, %Content.Video{}),
    do: Helpers.error(@codec, "Content.Video parts are not supported")

  defp validate_part(_role, %Content.Thinking{}),
    do: Helpers.error(@codec, "Content.Thinking parts are not supported")

  defp validate_part(_role, %Content.Raw{}),
    do: Helpers.error(@codec, "Content.Raw parts are not supported")

  defp validate_part(_role, _part), do: Helpers.error(@codec, "unsupported content part")

  defp validate_provider_options(%Request{} = request, %Config{} = config) do
    with :ok <-
           Helpers.validate_option_map(
             request.provider_options,
             @codec,
             "provider_options",
             @namespaces
           ) do
      Helpers.validate_option_map(
        config.default_provider_options,
        @codec,
        "default_provider_options",
        @namespaces
      )
    end
  end

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
    Helpers.validate_tool_spec(spec, @codec,
      builtin_tools: false,
      name_pattern: {@tool_name_pattern, @tool_name_max, "Converse"}
    )
  end

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
    |> Helpers.maybe_put("additionalModelRequestFields", additional_fields(request, config))
  end

  defp messages(messages, config), do: Enum.map(messages, &message(&1, config))

  defp message(%Message{role: role, content: content}, config) do
    %{"role" => role_name(role), "content" => Enum.map(content, &part(&1, config))}
  end

  defp role_name(:assistant), do: "assistant"
  defp role_name(_role), do: "user"

  defp part(%Content.Text{text: text}, _config), do: %{"text" => text}

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

  defp additional_fields(%Request{} = request, %Config{} = config) do
    request
    |> Config.provider_options(config)
    |> Map.get(:bedrock)
    |> absent_if_empty()
  end

  defp absent_if_empty(nil), do: nil
  defp absent_if_empty(map) when is_map(map) and map_size(map) == 0, do: nil
  defp absent_if_empty(value), do: value
end
