defmodule LlmCall.Protocol.Anthropic.Messages do
  @moduledoc """
  Anthropic Messages (`POST /v1/messages`).

  `system` is a top-level field, `max_tokens` is required, tool results are
  `tool_result` blocks inside a user turn, and reasoning is controlled by an
  explicit thinking budget rather than an effort level.

  `call_id` on a tool result is the Anthropic `tool_use_id`.
  """

  alias LlmCall.{
    Codec,
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

  @api_version "2023-06-01"
  @path "/v1/messages"
  @headers [{"content-type", "application/json"}, {"anthropic-version", @api_version}]
  @reserved_keys ~w(model messages system contents tools stream)
  @param_keys [:max_tokens, :temperature, :top_p, :top_k, :stop]

  @spec info() :: Codec.Info.t()
  def info do
    %Codec.Info{
      name: :anthropic_messages,
      protocol: :anthropic_messages,
      version: @api_version,
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
    end)
  end

  defp encode_tool_choice(_choice, []), do: nil
  defp encode_tool_choice(:auto, _tools), do: %{"type" => "auto"}
  defp encode_tool_choice(:none, _tools), do: %{"type" => "none"}
  defp encode_tool_choice(:required, _tools), do: %{"type" => "any"}
  defp encode_tool_choice({:tool, name}, _tools), do: %{"type" => "tool", "name" => name}

  defp encode_reasoning(nil), do: nil

  defp encode_reasoning(%Reasoning{budget_tokens: budget}) when is_integer(budget),
    do: %{"type" => "enabled", "budget_tokens" => budget}

  defp encode_reasoning(%Reasoning{effort: :none}), do: %{"type" => "disabled"}
  defp encode_reasoning(%Reasoning{}), do: nil

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
      %Message{role: :assistant, content: []} ->
        error("assistant message requires content")

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
         :ok <- reject_budget_with_effort(reasoning) do
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
  defp validate_tool_spec(%ToolSpec{name: name}) when is_binary(name) and name != "", do: :ok
  defp validate_tool_spec(%ToolSpec{}), do: error("function tool requires a name")
  defp validate_tool_spec(_spec), do: error("tools must be LlmCall.ToolSpec structs")

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
    first_error(messages, fn %Message{content: content} ->
      first_error(content, &validate_part/1)
    end)
  end

  defp validate_part(%Content.Text{}), do: :ok

  defp validate_part(%Content.Thinking{signature: nil}) do
    error("thinking content requires a signature")
  end

  defp validate_part(%Content.Thinking{}), do: :ok

  defp validate_part(%Content.Image{source: {:file_id, _file_id}}),
    do: error("image source {:file_id, id} is not supported")

  defp validate_part(%Content.Image{source: {:base64, _data}, media_type: nil}),
    do: error("base64 image requires media_type")

  defp validate_part(%Content.Image{source: {:base64, _data}}), do: :ok
  defp validate_part(%Content.Image{source: {:url, _url}}), do: :ok
  defp validate_part(%Content.Image{source: source}) when is_binary(source), do: :ok
  defp validate_part(%Content.Image{}), do: error("image source is not supported")

  defp validate_part(%Content.File{source: {:base64, _data}, media_type: nil}),
    do: error("base64 document requires media_type")

  defp validate_part(%Content.File{}), do: :ok
  defp validate_part(%Content.Raw{data: %{}}), do: :ok
  defp validate_part(%Content.Raw{}), do: error("raw content requires a map payload")
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
end
