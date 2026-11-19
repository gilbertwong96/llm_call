defmodule LlmCall.ApplicationTest do
  use ExUnit.Case, async: true

  alias LlmCall.Application

  test "the default pool is not started twice" do
    assert Application.default_children() == []
    assert Process.whereis(LlmCall.Finch) != nil
  end

  test "an unclaimed name gets a Finch child" do
    assert Application.default_children(LlmCall.UnclaimedTestPool) == [
             {Finch, name: LlmCall.UnclaimedTestPool}
           ]
  end

  test "a claimed name is left alone" do
    pid = self()

    {:ok, server} =
      Agent.start_link(fn -> :ok end, name: LlmCall.ClaimedTestPool)

    assert Application.default_children(LlmCall.ClaimedTestPool) == []
    assert is_pid(pid)
    Agent.stop(server)
  end
end
