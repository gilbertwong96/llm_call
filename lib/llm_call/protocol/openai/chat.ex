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
    ToolCall,
    ToolResult,
    ToolSpec
  }

  @path "/v1/chat/completions"
  @headers [{"content-type", "application/json"}]
  @reserved_keys ~w(model messages system contents tools stream)
  @param_keys [:temperature, :top_p, :max_tokens, :stop, :seed]
  @efforts [:none, :minimal, :low, :medium, :high]

  @spec info() :: LlmCall.Codec.Info.t()
  def info do
    %LlmCall.Codec.Info{
      name: :openai_chat,
      protocol: :openai_chat,
      version: nil,
      ir_version: 1
    }
  end

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
    |> Map.merge(provider_options(request, config))
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
    }
  end

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
    first_error(messages, fn %Message{content: content} -> validate_part_list(content) end)
  end

  defp validate_part_list(content) when is_list(content) do
    first_error(content, &validate_part/1)
  end

  defp validate_part_list(_content), do: error("message content must be a list of content parts")

  defp validate_part(%Content.Text{}), do: :ok

  defp validate_part(%Content.Image{source: {:base64, _data}, media_type: nil}),
    do: error("base64 image requires media_type")

  defp validate_part(%Content.Image{source: {:base64, _data}}), do: :ok
  defp validate_part(%Content.Image{source: {:url, _url}}), do: :ok
  defp validate_part(%Content.Image{source: source}) when is_binary(source), do: :ok
  defp validate_part(%Content.Image{}), do: error("image source is not supported")
  defp validate_part(%Content.File{}), do: error("file content is not supported")

  defp validate_part(%Content.Thinking{}),
    do: error("thinking content is not supported in a request")

  defp validate_part(%Content.Raw{}), do: error("raw content is not supported in a request")
  defp validate_part(%ToolCall{id: nil}), do: error("tool call requires an id")
  defp validate_part(%ToolCall{name: nil}), do: error("tool call requires a name")
  defp validate_part(%ToolCall{}), do: :ok
  defp validate_part(%ToolResult{call_id: nil}), do: error("tool result requires call_id")
  defp validate_part(%ToolResult{content: content}), do: validate_tool_result_content(content)
  defp validate_part(_part), do: error("unsupported content part")

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
end
