defmodule LlmCall.ModuledocTest do
  use ExUnit.Case, async: true

  test "no module opts out of documentation" do
    offenders =
      ["lib/**/*.ex", "test/support/**/*.ex", "packages/*/lib/**/*.ex", "packages/*/test/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(&(File.read!(&1) =~ "@moduledoc false"))

    assert offenders == [], "modules without a moduledoc: #{inspect(offenders)}"
  end
end
