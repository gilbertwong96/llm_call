defmodule LlmCall.Tools do
  @moduledoc """
  Expands the tool inputs a client accepts into `LlmCall.ToolSpec` structs.

  This module builds what a request sends; it never runs a tool. Running one is
  the caller's loop, and `ToolCall.run/4` is one implementation of it.

  Modules are an input form, not a canonical type: `expand/2` turns a module or
  a `{module, opts}` pair into `LlmCall.ToolSpec` structs, and
  `normalize_request/2` applies that to a whole request before any codec call.
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
  `{module, opts}`, contributes one spec per tool `ToolCall.describe/2` returns,
  in the module's declaration order. Errors are named after `codec`, so a caller
  sees which protocol refused the request.
  """
  @spec expand([input()], module()) :: {:ok, [ToolSpec.t()]} | {:error, Error.t()}
  def expand(tools, _codec) when is_list(tools) do
    {:ok, Enum.flat_map(tools, &expand_tool/1)}
  end

  def expand(_tools, codec), do: Helpers.error(codec.info().name, "tools must be a list")

  @doc """
  Normalizes a request's `tools` into `LlmCall.ToolSpec` structs.

  The request-level companion to `expand/2`: any code path that hands a
  `%LlmCall.Request{}` to a codec calls this first, so the codec sees only
  specs. Other fields pass through unchanged and an expansion error is returned
  as-is.
  """
  @spec normalize_request(LlmCall.Request.t(), module()) ::
          {:ok, LlmCall.Request.t()} | {:error, Error.t()}
  def normalize_request(%LlmCall.Request{} = request, codec) do
    with {:ok, specs} <- expand(request.tools, codec) do
      {:ok, %{request | tools: specs}}
    end
  end

  defp expand_tool(%ToolSpec{} = spec), do: [spec]

  defp expand_tool({module, opts}) when is_atom(module) and is_list(opts),
    do: descriptors(module, opts)

  defp expand_tool(module) when is_atom(module), do: descriptors(module, [])

  defp descriptors(module, opts) do
    for entry <- ToolCall.describe(module, opts) do
      %ToolSpec{name: entry.name, description: entry.description, parameters: entry.parameters}
    end
  end
end
