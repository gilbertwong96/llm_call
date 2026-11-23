defmodule LlmCall.DocsExamplesTest do
  use ExUnit.Case, async: true

  # The published Markdown is what a reader copies, and this project has shipped
  # examples that did not compile. Each `elixir` fence is parsed, and expression
  # blocks are compiled inside a function body so unused bindings surface without
  # executing anything.

  @files ["README.md", "examples/README.md", "docs/design.md", "CONTRIBUTING.md"]

  @root Path.expand("../..", __DIR__)

  setup_all do
    {:ok, blocks: Enum.map(@files, &{&1, blocks(&1)})}
  end

  test "every published Elixir example parses", %{blocks: per_file} do
    for {file, blocks} <- per_file, {start, code, _definition?} <- blocks do
      assert match?({:ok, _}, Code.string_to_quoted(code)),
             "#{file}:#{start} does not parse:\n\n#{code}"
    end

    # A broken extractor must not make this suite pass by finding nothing.
    assert Enum.count_until(blocks("README.md"), 11) == 11
  end

  test "no published example has an unused binding or an unassigned name", %{blocks: per_file} do
    for {file, blocks} <- per_file, {start, code, definition?} <- blocks, not definition? do
      for problem <- compile_problems(file, start, code) do
        flunk("#{file}:#{start}: #{problem}\n\n#{code}")
      end
    end
  end

  # A block that defines a module or a function cannot be wrapped in one, so it is
  # only syntax-checked.
  defp blocks(file) do
    path = Path.join(@root, file)
    lines = path |> File.read!() |> String.split("\n") |> Enum.with_index(1)
    assigned = assigned_names(File.read!(path))

    {blocks, _} =
      Enum.reduce(lines, {[], nil}, fn {line, number}, {blocks, current} ->
        cond do
          current == nil and String.starts_with?(line, "```elixir") ->
            {blocks, {number + 1, []}}

          current != nil and String.starts_with?(line, "```") ->
            {start, collected} = current
            code = collected |> Enum.reverse() |> Enum.join("\n")
            {[{start, code, definition?(code), assigned} | blocks], nil}

          current != nil ->
            {start, collected} = current
            {blocks, {start, [line | collected]}}

          true ->
            {blocks, nil}
        end
      end)

    blocks
    |> Enum.reverse()
    |> Enum.map(fn {start, code, definition?, _assigned} -> {start, code, definition?} end)
  end

  defp definition?(code) do
    code
    |> String.split("\n")
    |> Enum.any?(&String.match?(String.trim_leading(&1), ~r/^(defmodule |def |defp )/))
  end

  # A block is compiled on its own, so a name bound in another snippet looks
  # undefined. Names assigned anywhere in the file are that cross-reference.
  defp assigned_names(text) do
    ~r/^\s*([a-z_][A-Za-z0-9_]*)\s*(?:=[^=]|<-)/m
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp compile_problems(file, start, code) do
    assigned = assigned_names(File.read!(Path.join(@root, file)))

    wrapped =
      "defmodule LlmCall.DocsExample#{start} do\n  def run do\n#{indent(code)}\n  end\nend"

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        # An undefined variable raises CompileError and logs the reason to stderr, so
        # the captured lines name the problem; the raise carries only "errors have been
        # logged".
        try do
          Code.compile_string(wrapped, "docs_example_#{start}.exs")
        rescue
          _compile_error -> :ok
        end
      end)

    stderr
    |> String.split("\n")
    |> Enum.filter(
      &(String.contains?(&1, "is unused") or String.contains?(&1, "undefined variable"))
    )
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line ->
      case Regex.run(~r/undefined variable "([^"]+)"/, line) do
        [_, name] -> name in assigned
        nil -> false
      end
    end)
  end

  defp indent(code) do
    pad = "    " |> String.duplicate(1)
    code |> String.split("\n") |> Enum.map_join("\n", &if(&1 == "", do: "", else: pad <> &1))
  end
end
