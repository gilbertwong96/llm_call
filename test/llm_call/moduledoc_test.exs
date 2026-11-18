defmodule LlmCall.ModuledocTest do
  use ExUnit.Case, async: true

  test "no module opts out of documentation" do
    offenders =
      ["lib/**/*.ex", "test/support/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(&(File.read!(&1) =~ "@moduledoc false"))

    assert offenders == [], "modules without a moduledoc: #{inspect(offenders)}"
  end

  test "every application module carries a moduledoc" do
    missing =
      for module <- elem(:application.get_key(:llm_call, :modules), 1),
          {:docs_v1, _, _, _, :none, _, _} <- [Code.fetch_docs(module)],
          do: module

    assert missing == [], "modules without a moduledoc: #{inspect(missing)}"
  end
end
