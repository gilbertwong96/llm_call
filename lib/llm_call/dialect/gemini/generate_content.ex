defmodule LlmCall.Dialect.Gemini.GenerateContent do
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

  Tool `parameters` and `responseSchema` must already be in Gemini's OpenAPI
  subset. The codec rejects a lowercase `type`, `additionalProperties`,
  `$ref`/`$defs`, `prefixItems`, `oneOf` or `const` as a `:validation` error
  rather than sending a request the provider would reject.

  `provider_options` accepts `:gemini` and its `:google` alias. The alias is
  collapsed per source before merging, so a request value wins over a config
  default even when the two use different names, and nested native objects are
  deep-merged (a request can extend a defaulted `generationConfig`).

  `finishReason` maps into the canonical union: `CONTINUATION` is a resumable
  token-limit stop, so it reads as `:max_tokens`; the content-policy reasons (the
  safety, recitation, blocklist, language, image-safety, and escalation family)
  read as `:content_filter`; and the reasons that mean the generation failed
  (`MALFORMED_FUNCTION_CALL`, `UNEXPECTED_TOOL_CALL`, `TOO_MANY_TOOL_CALLS`,
  `MISSING_THOUGHT_SIGNATURE`, `MALFORMED_RESPONSE`, `NO_IMAGE`, `IMAGE_OTHER`,
  `PUP_LIMITED_DISABLED`) read as `:error`. The candidate's `continuationToken`
  has no canonical field and stays in `Response.raw`.
  """

  @api_version "v1beta"
  @headers [{"content-type", "application/json"}]
  @envelope_keys ~w(contents systeminstruction tools toolconfig)
  @generation_config_reserved_keys ~w(temperature topp topk maxoutputtokens stopsequences
                                     responsemimetype responseschema thinkingconfig
                                     responsemodalities)
  @tool_reserved_keys ~w(name description parameters)
  # Parts whose payload must survive as Raw even when a signature rides along.
  @content_keys ~w(inlineData fileData executableCode codeExecutionResult)

  @gemini_schema_unsupported ~w(additionalProperties $ref $defs prefixItems oneOf const allOf not)
  @gemini_schema_map_keys ~w(items not contains propertyNames if then else additionalProperties
                             unevaluatedProperties unevaluatedItems contentSchema)
  @gemini_schema_list_keys ~w(anyOf allOf oneOf prefixItems)
  @gemini_schema_map_of_maps_keys ~w(properties patternProperties dependentSchemas definitions $defs)
  @builtin_tools :passthrough
  @reasoning_reserved_keys ~w(thinkingbudget thinkinglevel)
  # FunctionDeclaration.name: "Must start with a letter or an underscore. Must
  # be a-z, A-Z, 0-9, or contain underscores, dots, colons and dashes, with a
  # maximum length of 128."
  @function_name_pattern ~r/\A[a-zA-Z_][a-zA-Z0-9_.:-]*\z/
  @function_name_max 128
  @param_keys [:temperature, :top_p, :top_k, :max_tokens, :stop]
  @param_spec %{
    temperature: {:number, 0, 2},
    top_p: {:number, 0, 1},
    top_k: {:integer, 0, :infinity},
    max_tokens: {:integer, 1, :infinity},
    stop: {:stop, 4}
  }
  @efforts [nil, :none, :low, :high]
  @retryable_statuses ~w(RESOURCE_EXHAUSTED UNAVAILABLE INTERNAL DEADLINE_EXCEEDED)

  @namespaces [:gemini, :google]

  @native_options %{
    "safetySettings" => :list,
    "cachedContent" => :string,
    "labels" => :map
  }

  use LlmCall.Dialect.Adapter, codec: :gemini_generate_content, encode: false

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
    with :ok <- validate_request(request, config),
         {:ok, body} <- body(request, config) do
      {:ok,
       %EncodedRequest{
         method: :post,
         path: path(request),
         query: query(request),
         headers: @headers,
         body: body
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
         :ok <- validate_parts(request.messages, config.json) do
      validate_provider_options(request, config)
    end
  end

  defp path(%Request{model: model, stream: true}),
    do: "/v1beta/models/#{model}:streamGenerateContent"

  defp path(%Request{model: model}), do: "/v1beta/models/#{model}:generateContent"

  defp query(%Request{stream: true}), do: %{"alt" => "sse"}
  defp query(%Request{}), do: %{}

  defp body(request, config) do
    body =
      %{}
      |> Map.put("contents", Enum.map(request.messages, &encode_message(&1, config.json)))
      |> Helpers.maybe_put("systemInstruction", encode_system(request.system))
      |> Helpers.maybe_put("tools", encode_tools(request.tools))
      |> Helpers.maybe_put("toolConfig", encode_tool_config(request.tool_choice, request.tools))
      |> Helpers.maybe_put("generationConfig", encode_generation_config(request))
      |> Config.deep_merge(provider_options(request, config))

    {:ok, body}
  end

  defp encode_message(%Message{role: role, content: content}, json) do
    %{
      "role" => if(role == :assistant, do: "model", else: "user"),
      "parts" => Enum.map(content, &encode_part(&1, json))
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

  defp encode_part(%Content.Text{text: text}, _json), do: %{"text" => text}

  defp encode_part(%Content.Thinking{text: text, signature: signature}, _json) do
    %{"text" => text, "thought" => true} |> Helpers.maybe_put("thoughtSignature", signature)
  end

  defp encode_part(%Content.Image{source: {:base64, data}, media_type: media_type}, _json) do
    %{"inlineData" => %{"mimeType" => media_type, "data" => data}}
  end

  defp encode_part(%Content.Image{source: {:url, url}, media_type: media_type}, _json) do
    %{"fileData" => %{"fileUri" => url} |> Helpers.maybe_put("mimeType", media_type)}
  end

  defp encode_part(%Content.Image{source: url}, _json) when is_binary(url) do
    %{"fileData" => %{"fileUri" => url}}
  end

  defp encode_part(%Content.File{source: {:base64, data}, media_type: media_type}, _json) do
    %{"inlineData" => %{"mimeType" => media_type, "data" => data}}
  end

  defp encode_part(%Content.File{source: {:url, url}, media_type: media_type}, _json) do
    %{"fileData" => %{"fileUri" => url} |> Helpers.maybe_put("mimeType", media_type)}
  end

  defp encode_part(%Content.File{source: url}, _json) when is_binary(url) do
    %{"fileData" => %{"fileUri" => url}}
  end

  defp encode_part(%ToolCall{} = call, json) do
    %{
      "functionCall" => %{
        "name" => call.name,
        "args" => call.arguments || Helpers.decode_raw_arguments(call.raw_arguments, json) || %{}
      }
    }
  end

  defp encode_part(%ToolResult{} = result, _json) do
    response =
      case result.is_error do
        true -> %{"error" => tool_result_text(result.content)}
        _other -> %{"result" => tool_result_text(result.content)}
      end

    %{"functionResponse" => %{"name" => result.name, "response" => response}}
  end

  defp encode_part(%Content.Raw{data: %{} = data}, _json), do: data

  defp tool_result_text(content) when is_binary(content), do: content
  defp tool_result_text(parts) when is_list(parts), do: Enum.map_join(parts, "\n", & &1.text)

  defp encode_tools([]), do: nil

  defp encode_tools(specs) do
    {declarations, builtins} =
      Enum.split_with(specs, fn %ToolSpec{kind: kind} -> kind != :builtin end)

    declaration_entries =
      Enum.map(declarations, fn %ToolSpec{} = spec ->
        %{"name" => spec.name}
        |> Helpers.maybe_put("description", spec.description)
        |> Helpers.maybe_put("parameters", spec.parameters)
        |> Config.deep_merge(tool_options(spec))
      end)

    function_entry =
      case declaration_entries do
        [] -> []
        entries -> [%{"functionDeclarations" => entries}]
      end

    builtin_entries =
      Enum.map(builtins, fn %ToolSpec{name: name} = spec ->
        %{name => Map.new(tool_options(spec))}
      end)

    function_entry ++ builtin_entries
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
    Helpers.alias_options(
      config.default_provider_options,
      request.provider_options,
      :gemini,
      :google
    )
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

  defp validate_params(params),
    do: Helpers.validate_params_with_spec(params, @param_keys, @param_spec, @codec)

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%Reasoning{} = reasoning) do
    with :ok <- validate_effort(reasoning.effort),
         :ok <- validate_budget(reasoning.budget_tokens),
         :ok <- Helpers.reject(reasoning.summary, @codec, "reasoning summary is not supported"),
         :ok <- reject_effort_with_budget(reasoning) do
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
              (is_boolean(strict) or is_nil(strict)) and strict != true do
    validate_gemini_schema(schema, "responseSchema")
  end

  defp validate_output({:json_schema, _name, _schema, true}),
    do: Helpers.error(@codec, "strict json_schema is not supported")

  defp validate_output(output),
    do: Helpers.error(@codec, "output #{inspect(output)} is not supported")

  defp validate_tool_spec(spec) do
    with :ok <-
           Helpers.validate_tool_spec(spec, @codec,
             options: true,
             builtin_tools: @builtin_tools,
             name_pattern: {@function_name_pattern, @function_name_max, "Gemini"}
           ),
         :ok <- validate_tool_parameters(spec) do
      Helpers.validate_option_keys(spec.provider_options, @tool_reserved_keys, @codec)
    end
  end

  defp validate_tool_parameters(%ToolSpec{kind: :function, parameters: parameters})
       when is_map(parameters) do
    validate_gemini_schema(parameters, "tool parameters")
  end

  defp validate_tool_parameters(_spec), do: :ok

  defp validate_gemini_schema(schema, label) when is_map(schema) do
    with :ok <- validate_gemini_schema_keys(schema, label),
         :ok <- validate_gemini_schema_type(schema, label) do
      schema
      |> Map.to_list()
      |> Helpers.first_error(fn {key, value} ->
        validate_gemini_schema_child(key, value, label)
      end)
    end
  end

  defp validate_gemini_schema(schema, label) when is_list(schema) do
    Helpers.first_error(schema, &validate_gemini_schema(&1, label))
  end

  defp validate_gemini_schema(_schema, _label), do: :ok

  defp validate_gemini_schema_keys(schema, label) do
    Enum.find_value(@gemini_schema_unsupported, :ok, fn key ->
      if Map.has_key?(schema, key) do
        Helpers.error(@codec, "#{label}: Gemini cannot express `#{key}`")
      end
    end)
  end

  defp validate_gemini_schema_type(schema, label) do
    case Map.fetch(schema, "type") do
      :error ->
        :ok

      {:ok, type} when is_binary(type) ->
        if type == String.upcase(type) do
          :ok
        else
          Helpers.error(
            @codec,
            "#{label}: Gemini `type` must be uppercase, got: #{inspect(type)}"
          )
        end

      {:ok, type} ->
        Helpers.error(@codec, "#{label}: Gemini `type` must be uppercase, got: #{inspect(type)}")
    end
  end

  defp validate_gemini_schema_child(key, value, label) when key in @gemini_schema_map_keys,
    do: validate_gemini_schema(value, "#{label}.#{key}")

  defp validate_gemini_schema_child(key, value, label) when key in @gemini_schema_list_keys,
    do: validate_gemini_schema(value, "#{label}.#{key}")

  defp validate_gemini_schema_child(key, value, label)
       when key in @gemini_schema_map_of_maps_keys and is_map(value) do
    value
    |> Map.to_list()
    |> Helpers.first_error(fn {name, schema} ->
      validate_gemini_schema(schema, "#{label}.#{key}.#{name}")
    end)
  end

  defp validate_gemini_schema_child(_key, _value, _label), do: :ok

  defp validate_tool_choice(:auto, _tools), do: :ok
  defp validate_tool_choice(:none, _tools), do: :ok

  defp validate_tool_choice(choice, []) when choice in [:required] or is_tuple(choice),
    do: Helpers.error(@codec, "tool_choice requires at least one tool")

  defp validate_tool_choice(:required, _tools), do: :ok

  defp validate_tool_choice({:tool, name}, tools) when is_binary(name) and name != "",
    do: Helpers.validate_chosen_tool(name, tools, @codec)

  defp validate_tool_choice({:tool, _name}, _tools),
    do: Helpers.error(@codec, "tool_choice tool name is required")

  defp validate_tool_choice({:allowed, names}, tools) when is_list(names),
    do: Helpers.validate_allowed_tools(names, tools, @codec)

  defp validate_tool_choice(choice, _tools),
    do: Helpers.error(@codec, "tool_choice #{inspect(choice)} is not supported")

  defp validate_parts(messages, json),
    do: Helpers.validate_parts(messages, @codec, &validate_part_shape(&1, &2, json))

  defp validate_part_shape(_role, %Content.Text{}, _json), do: :ok
  defp validate_part_shape(_role, %Content.Thinking{}, _json), do: :ok

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
       do: Helpers.error(@codec, "base64 file requires media_type")

  defp validate_part_shape(_role, %Content.File{source: {:base64, _data}}, _json), do: :ok
  defp validate_part_shape(_role, %Content.File{source: {:url, _url}}, _json), do: :ok

  defp validate_part_shape(_role, %Content.File{source: source}, _json)
       when is_binary(source),
       do: :ok

  defp validate_part_shape(_role, %Content.File{}, _json),
    do: Helpers.error(@codec, "file source is not supported")

  defp validate_part_shape(_role, %Content.Raw{data: %{}}, _json), do: :ok

  defp validate_part_shape(_role, %Content.Raw{}, _json),
    do: Helpers.error(@codec, "raw content requires a map payload")

  defp validate_part_shape(_role, %ToolCall{name: nil}, _json),
    do: Helpers.error(@codec, "tool call requires a name")

  defp validate_part_shape(_role, %ToolCall{} = call, json),
    do: Helpers.validate_tool_call_arguments(call, @codec, json)

  defp validate_part_shape(_role, %ToolResult{name: nil}, _json),
    do: Helpers.error(@codec, "tool result requires a name")

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
         :ok <- validate_native_options(request.provider_options, "provider_options") do
      validate_native_options(config.default_provider_options, "default_provider_options")
    end
  end

  defp validate_native_options(options, label) do
    native = Helpers.alias_options(%{}, options, :gemini, :google)

    with :ok <- Helpers.validate_option_keys(native, @envelope_keys, @codec),
         :ok <- Helpers.validate_native_options(native, @native_options, @codec, label) do
      validate_generation_config(native, label)
    end
  end

  defp validate_generation_config(options, label) do
    case Map.get(options, "generationConfig") do
      nil ->
        :ok

      value when is_map(value) ->
        Helpers.validate_option_keys(value, @generation_config_reserved_keys, @codec)

      _other ->
        Helpers.error(@codec, "#{label}.generationConfig must be a map")
    end
  end

  @impl true
  def decode_response(term, %Config{} = config) when is_map(term) do
    case term["candidates"] do
      [candidate | extra] when is_map(candidate) ->
        decode_candidate(candidate, extra, term, config)

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

  defp decode_candidate(candidate, extra, term, config) do
    case fetch_parts(candidate) do
      {:ok, parts} ->
        decode_candidate_parts(candidate, extra, parts, term, config)

      {:error, _error} = error ->
        candidate_without_content(candidate, extra, term, config, error)
    end
  end

  defp decode_candidate_parts(candidate, extra, parts, term, config) do
    case decode_parts(parts) do
      {:ok, decoded} ->
        content = decoded ++ Enum.map(extra, &%Content.Raw{type: "candidate", data: &1})

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
        error
    end
  end

  @impl true
  def decode_error(payload, %Config{} = config) do
    Helpers.decode_provider_error(payload, config, @codec, ["status"], @retryable_statuses)
  end

  @impl true
  def capabilities(%Request{}, _config) do
    %Capabilities{
      tools: true,
      builtin_tools: @builtin_tools,
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
    with :ok <- validate_stream_chunk(term) do
      data = StreamState.data(state)
      data = %{data | usage: accumulate_usage(data.usage, term["usageMetadata"])}

      {events, data} = chunk_events(term, config, data)
      {:ok, events, StreamState.new(__MODULE__, data)}
    end
  end

  def decode_stream_event(_term, _config, %StreamState{} = state), do: {:ok, [], state}

  defp validate_stream_chunk(%{"candidates" => [candidate | _]}) when is_map(candidate) do
    case candidate["content"] do
      nil ->
        :ok

      content when is_map(content) ->
        case content["parts"] do
          nil -> :ok
          parts when is_list(parts) -> :ok
          _other -> {:error, invalid_response("content.parts must be a list")}
        end

      _other ->
        {:error, invalid_response("candidate content must be an object")}
    end
  end

  defp validate_stream_chunk(_term), do: :ok

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

  defp decode_part(%{"text" => text, "thought" => true} = part) when is_binary(text) do
    %Content.Thinking{text: text, signature: part["thoughtSignature"]}
  end

  defp decode_part(%{"text" => text}) when is_binary(text), do: %Content.Text{text: text}

  defp decode_part(%{"functionCall" => call} = part) when is_map(call) do
    case call["args"] do
      args when is_nil(args) or is_map(args) ->
        %ToolCall{
          id: nil,
          name: call["name"],
          arguments: args || %{},
          raw_arguments: nil,
          arguments_error: nil
        }

      _other ->
        %Content.Raw{type: "functionCall", data: part}
    end
  end

  defp decode_part(%{"inlineData" => %{"data" => bytes} = data})
       when is_binary(bytes) and bytes != "" do
    %Content.Image{source: {:base64, bytes}, media_type: data["mimeType"]}
  end

  defp decode_part(%{"fileData" => %{"fileUri" => file_uri} = data})
       when is_binary(file_uri) and file_uri != "" do
    %Content.File{
      source: {:url, file_uri},
      media_type: data["mimeType"],
      filename: nil
    }
  end

  defp decode_part(%{"functionResponse" => %{"name" => name} = response}) do
    case response["response"] do
      nil ->
        %ToolResult{name: name, content: "", is_error: false}

      body when is_map(body) ->
        %ToolResult{
          name: name,
          content: body["result"] || body["error"] || "",
          is_error: Map.has_key?(body, "error")
        }

      _other ->
        :error
    end
  end

  defp decode_part(part) when is_map(part) do
    %Content.Raw{type: part |> Map.keys() |> Enum.sort() |> List.first(), data: part}
  end

  defp decode_part(_part), do: :error

  defp decode_parts(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case decode_part(part) do
        :error ->
          {:halt, {:error, invalid_response("content part is not an object")}}

        decoded ->
          {:cont, {:ok, [decoded | acc]}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp response_stop_reason(nil, _content), do: :unknown

  defp response_stop_reason("STOP", content) do
    if Enum.any?(content, &is_struct(&1, ToolCall)), do: :tool_calls, else: :end_turn
  end

  defp response_stop_reason("MAX_TOKENS", _content), do: :max_tokens

  # A token-limit stop that can be resumed with the candidate's `continuationToken`.
  defp response_stop_reason("CONTINUATION", _content), do: :max_tokens

  # Content-policy stops, text and image alike, plus the escalation rule.
  defp response_stop_reason(reason, _content)
       when reason in [
              "SAFETY",
              "RECITATION",
              "LANGUAGE",
              "BLOCKLIST",
              "PROHIBITED_CONTENT",
              "SPII",
              "IMAGE_SAFETY",
              "IMAGE_PROHIBITED_CONTENT",
              "IMAGE_RECITATION",
              "ESCALATION"
            ] do
    :content_filter
  end

  # The provider reported a generation that failed instead of stopping normally.
  defp response_stop_reason(reason, _content)
       when reason in [
              "MALFORMED_FUNCTION_CALL",
              "UNEXPECTED_TOOL_CALL",
              "TOO_MANY_TOOL_CALLS",
              "MISSING_THOUGHT_SIGNATURE",
              "MALFORMED_RESPONSE",
              "NO_IMAGE",
              "IMAGE_OTHER",
              "PUP_LIMITED_DISABLED"
            ] do
    :error
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
      input_tokens: Helpers.token(wire["promptTokenCount"]) || base.input_tokens,
      output_tokens: Helpers.token(wire["candidatesTokenCount"]) || base.output_tokens,
      total_tokens: Helpers.token(wire["totalTokenCount"]) || base.total_tokens,
      cache_read_tokens: Helpers.token(wire["cachedContentTokenCount"]) || base.cache_read_tokens,
      cache_write_tokens: base.cache_write_tokens,
      reasoning_tokens: Helpers.token(wire["thoughtsTokenCount"]) || base.reasoning_tokens
    }
  end

  defp accumulate_usage(current, _wire), do: current

  defp usage?(nil), do: false

  defp usage?(%Usage{} = usage) do
    usage.input_tokens || usage.output_tokens || usage.total_tokens || usage.cache_read_tokens ||
      usage.reasoning_tokens
  end

  defp chunk_events(term, config, data) do
    case term["candidates"] do
      [candidate | _] when is_map(candidate) ->
        parts = Helpers.nested(candidate, ["content", "parts"])
        parts = if is_list(parts), do: parts, else: []
        {part_events, data} = parts_events(parts, term, config, data)

        {finish_events, data} =
          finish_events(candidate["finishReason"], term, config, data)

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
      arguments: encoded_arguments(call["args"], config.json),
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

  # A thought part carrying only a signature signs a block whose text arrived earlier
  # and is the `thinking` marker the README's `merge/2` fold expects. A part that also
  # carries content — an inline image, a code block — keeps that payload as `Raw`,
  # which is what the non-streaming decoder does with the same part.
  defp part_events(%{"thoughtSignature" => signature} = part, term, config, data)
       when is_binary(signature) do
    if Enum.any?(@content_keys, &is_map_key(part, &1)) do
      raw_part_events(part, term, config, data)
    else
      thinking = %StreamDelta.Thinking{text: "", signature: signature}
      {[Helpers.event(:thinking_delta, nil, thinking, term, config)], data}
    end
  end

  # §8.1 and §12: a field the codec does not know must reach the caller as `Raw`,
  # never as silence. The non-streaming decoder wraps the same part in `Content.Raw`.
  defp part_events(part, term, config, data) when is_map(part),
    do: raw_part_events(part, term, config, data)

  # An empty `text` part carries nothing canonical in a stream, so it reaches the
  # caller as `Raw` rather than as an empty delta; the non-streaming decoder keeps it
  # as `Content.Text` because it is decoding a whole response, not a delta.
  defp part_events(_part, _term, _config, data), do: {[], data}

  defp raw_part_events(part, term, config, data) do
    {[Helpers.event(:message_delta, nil, %StreamDelta.Raw{data: part}, term, config)], data}
  end

  defp encoded_arguments(args, json) do
    case LlmCall.JSON.encode(json, args || %{}) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> nil
    end
  end

  defp finish_events(nil, _term, _config, data), do: {[], data}

  defp finish_events(reason, term, config, data) do
    stop =
      cond do
        reason != "STOP" -> response_stop_reason(reason, [])
        # Only a call this codec actually emitted counts. A `functionCall` whose
        # value is not a map never produced one, so claiming :tool_calls would leave
        # an agent loop waiting for a call that never arrives.
        data.next_tool_index > 0 -> :tool_calls
        true -> :end_turn
      end

    delta = %StreamDelta.MessageDelta{stop_reason: stop, usage: nil}

    {[Helpers.event(:message_delta, nil, delta, term, config)], %{data | stop_reason: stop}}
  end
end
