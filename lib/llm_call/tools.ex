defmodule LlmCall.Tools do
  @moduledoc """
  Expands the tool inputs a client accepts into `LlmCall.ToolSpec` structs.

  This module builds what a request sends; it never runs a tool. Running one is
  the caller's loop, and `ToolCall.run/4` is one implementation of it.

  Modules are an input form, not a canonical type: `expand/2` turns a module or
  a `{module, opts}` pair into `LlmCall.ToolSpec` structs with the schema
  projected for the codec's protocol, and `normalize_request/2` applies that to a
  whole request before the codec at every public request entry point except
  `capabilities/3`, which reads no tools.
  """

  alias LlmCall.Dialect.Helpers
  alias LlmCall.{Error, ToolSpec}

  @typedoc """
  A tool entry: a spec to keep, or a `ToolCall` module to expand.
  """
  @type input :: ToolSpec.t() | module() | {module(), keyword()}

  @doc """
  Expands `tools` into one spec per tool.

  A `%LlmCall.ToolSpec{}` passes through unchanged; a module, or
  `{module, opts}`, contributes one spec per tool, in the module's declaration
  order, with the schema projected for `codec`'s protocol. `opts` may carry
  `strict: boolean()`: `true` is OpenAI's strict schema, `false` is treated as
  absent, and every other codec rejects `true`. Errors are named after `codec`,
  so a caller sees which protocol refused the request; an entry that is none of
  the accepted forms, a module that does not `use ToolCall`, and a schema the
  codec cannot express are `:validation` errors rather than raises.
  """
  @spec expand([input()], module()) :: {:ok, [ToolSpec.t()]} | {:error, Error.t()}
  def expand(tools, codec) when is_list(tools) do
    with {:ok, expanded} <- Helpers.map_ok(tools, &expand_tool(&1, codec)) do
      {:ok, Enum.concat(expanded)}
    end
  end

  def expand(_tools, codec), do: Helpers.error(codec.info().name, "tools must be a list")

  @doc """
  Normalizes a request's `tools` into `LlmCall.ToolSpec` structs.

  The request-level companion to `expand/2`: `complete/3`, `stream/3`, `encode/3`,
  `validate_request/3` and `init_stream/3` call this before the codec, so the
  codec sees only specs; `capabilities/3` is the one public request entry point
  that does not, because it reads no tools. Other fields pass through unchanged
  and an expansion error is returned as-is.
  """
  @spec normalize_request(LlmCall.Request.t(), module()) ::
          {:ok, LlmCall.Request.t()} | {:error, Error.t()}
  def normalize_request(%LlmCall.Request{} = request, codec) do
    with {:ok, specs} <- expand(request.tools, codec) do
      {:ok, %{request | tools: specs}}
    end
  end

  defp expand_tool(%ToolSpec{} = spec, _codec), do: {:ok, [spec]}

  defp expand_tool({module, opts}, codec) when is_atom(module) and is_list(opts) do
    with {:ok, strict} <- strict_option(opts, codec) do
      specs_for(module, strict, codec)
    end
  end

  defp expand_tool(module, codec) when is_atom(module), do: specs_for(module, nil, codec)

  defp expand_tool(entry, codec) do
    Helpers.error(
      codec.info().name,
      "tool entry must be a LlmCall.ToolSpec, a module, or a {module, opts} pair, " <>
        "got: #{inspect(entry)}"
    )
  end

  defp strict_option(opts, codec) do
    case Keyword.get(opts, :strict) do
      nil ->
        {:ok, nil}

      false ->
        {:ok, nil}

      true ->
        {:ok, true}

      other ->
        Helpers.error(codec.info().name, "tool strict must be a boolean, got: #{inspect(other)}")
    end
  end

  @spec projection(atom()) :: :openai | :gemini | :neutral
  defp projection(:gemini_generate_content), do: :gemini
  defp projection(protocol) when protocol in [:openai_chat, :openai_responses], do: :openai
  defp projection(_protocol), do: :neutral

  defp specs_for(module, strict, codec) do
    with {:ok, tools} <- tools_for(module, codec) do
      Helpers.map_ok(tools, &spec_for(&1, module, strict, codec))
    end
  end

  defp tools_for(module, codec) do
    {:ok, ToolCall.tools(module)}
  rescue
    error in ArgumentError -> Helpers.error(codec.info().name, Exception.message(error))
  end

  defp spec_for(tool, module, strict, codec) do
    {:ok, project(tool, strict, projection(codec.info().protocol))}
  rescue
    error in ArgumentError ->
      Helpers.error(
        codec.info().name,
        "cannot render tool #{inspect(tool.name)} in #{inspect(module)}: " <>
          Exception.message(error)
      )
  end

  defp project(tool, strict, :neutral) do
    parameters = ToolCall.Emit.Schema.params(tool, strict: strict)
    to_spec(tool.name, tool.description || tool.name, parameters, strict)
  end

  defp project(tool, strict, :gemini) do
    entry = ToolCall.emit(tool, :gemini)
    to_spec(entry["name"], entry["description"], entry["parameters"], strict)
  end

  defp project(tool, strict, :openai) do
    # LlmCall renders OpenAI's `strict` inside `function`, so the sibling
    # `strict` ToolCall.emit/3 adds is dropped here.
    %{"function" => function} = ToolCall.emit(tool, :openai, strict: strict)
    to_spec(function["name"], function["description"], function["parameters"], strict)
  end

  defp to_spec(name, description, parameters, strict) do
    %ToolSpec{
      name: name,
      description: description,
      parameters: parameters,
      strict: strict
    }
  end
end
