defmodule LlmCall.CoverToLcov do
  @moduledoc """
  Converts the `.coverdata` that `mix test --cover --export-coverage` writes into
  lcov, which is what codecov reads.

  Elixir's built-in cover has no machine-readable export: `--export-coverage`
  writes an Erlang term, and the HTML report is for humans. ExCoveralls would emit
  JSON, but it insists on replacing the coverage tool, and that would drop the
  `test_coverage: [summary: [threshold: 85]]` gate in `mix.exs`.

  Not part of the package: `package: [files: ...]` in `mix.exs` lists `lib/` and
  the documents only.
  """

  @doc """
  Reads `input` and writes `output`, returning the number of source files written.

  Usage from the project root:

      MIX_ENV=test mix run --no-start scripts/cover_to_lcov.exs
  """
  @spec run(Path.t(), Path.t()) :: {:ok, non_neg_integer()}
  def run(input \\ "cover/default.coverdata", output \\ "cover/lcov.info") do
    unless File.exists?(input) do
      Mix.raise("#{input} is missing; run `mix test --cover --export-coverage default` first")
    end

    Mix.ensure_application!(:tools)
    Application.ensure_all_started(:tools)
    :cover.start()
    :ok = :cover.import(String.to_charlist(input))

    records =
      modules()
      |> Enum.reject(&ignored?/1)
      |> Enum.map(&record/1)
      |> Enum.reject(&is_nil/1)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, records)

    {:ok, length(records)}
  end

  # `:cover.analyse(module, :coverage, :line)` returns `{{module, line}, {covered, _}}`
  # where `covered` is 1 or 0; the second element is not the hit count. Line 0 is
  # the module prologue and is not a source line.
  defp record(module) do
    with {:ok, lines} <- :cover.analyse(module, :coverage, :line),
         source when is_binary(source) <- source_path(module),
         [_ | _] = lines <- Enum.reject(lines, fn {{_module, line}, _} -> line == 0 end) do
      data =
        lines
        |> Enum.sort_by(fn {{_module, line}, _} -> line end)
        |> Enum.map(fn {{_module, line}, {covered, _}} -> "DA:#{line},#{covered}\n" end)

      [["SF:", source, "\n"], data, "end_of_record\n"]
    else
      _nothing_to_report -> nil
    end
  end

  # The same exclusion the coverage gate applies, read from mix.exs so the two
  # cannot drift.
  defp ignored?(module) do
    ignore = Mix.Project.config()[:test_coverage][:ignore_modules] || []
    name = inspect(module)
    Enum.any?(ignore, &Regex.match?(&1, name))
  end

  # The compiled beams include protocol implementations, which are not in the
  # application's module list and one of which is a Stream impl with lines.
  defp modules do
    "_build/#{Mix.env()}/lib/llm_call/ebin/*.beam"
    |> Path.wildcard()
    |> Enum.map(fn path -> path |> Path.basename(".beam") |> String.to_atom() end)
  end

  # The source path of a compiled module, relative to the project root, because
  # codecov resolves paths against the repository.
  defp source_path(module) do
    with beam when is_list(beam) <- :code.which(module),
         {:ok, {_module, chunks}} <- :beam_lib.chunks(beam, [:compile_info]),
         source when is_list(source) <- Keyword.get(chunks[:compile_info], :source),
         path = to_string(source),
         false <- path == Path.relative_to(path, File.cwd!()) do
      Path.relative_to(path, File.cwd!())
    else
      _no_source -> nil
    end
  end
end

case LlmCall.CoverToLcov.run() do
  {:ok, count} -> IO.puts("cover_to_lcov: wrote #{count} files")
end
