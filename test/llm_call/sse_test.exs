defmodule LlmCall.SSETest do
  use ExUnit.Case, async: true

  alias LlmCall.SSE

  test "parses one event" do
    {payloads, _state} = SSE.parse(SSE.new(), "data: hello\n\n")
    assert payloads == ["hello"]
  end

  test "joins multiple data lines with a newline" do
    {payloads, _state} = SSE.parse(SSE.new(), "data: one\ndata: two\n\n")
    assert payloads == ["one\ntwo"]
  end

  test "ignores comments and non-data fields" do
    chunk = ": keepalive\nevent: message\nid: 1\nretry: 10\ndata: x\n\n"
    assert {["x"], _state} = SSE.parse(SSE.new(), chunk)
  end

  test "a chunk split mid-line keeps the remainder" do
    {first, state} = SSE.parse(SSE.new(), "data: he")
    assert first == []

    {second, _state} = SSE.parse(state, "llo\n\n")
    assert second == ["hello"]
  end

  test "a chunk split mid-event keeps the remainder" do
    {first, state} = SSE.parse(SSE.new(), "data: a\n\ndata: b")
    assert first == ["a"]

    {second, _state} = SSE.parse(state, "\n\n")
    assert second == ["b"]
  end

  test "flush returns a trailing event without a blank line" do
    {payloads, state} = SSE.parse(SSE.new(), "data: tail")
    assert payloads == []
    assert {["tail"], %SSE{buffer: ""}} = SSE.flush(state)
  end

  test "flush on a clean body returns nothing" do
    {_payloads, state} = SSE.parse(SSE.new(), "data: a\n\n")
    assert {[], %SSE{buffer: ""}} = SSE.flush(state)
  end

  test "normalises CRLF" do
    assert {["a"], _state} = SSE.parse(SSE.new(), "data: a\r\n\r\n")
  end
end
