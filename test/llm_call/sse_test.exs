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

  test "ignores comments, event and id fields" do
    chunk = ": keepalive\nevent: message\nid: 1\ndata: x\n\n"
    assert {["x"], _state} = SSE.parse(SSE.new(), chunk)
  end

  test "keeps the server's retry hint on the state" do
    assert {["x"], %SSE{retry_ms: 5_000}} = SSE.parse(SSE.new(), "retry: 5000\ndata: x\n\n")
  end

  test "the retry hint is carried over and kept across chunks" do
    {_, state} = SSE.parse(SSE.new(), "retry: 250\ndata: a\n\n")
    assert {["b"], %SSE{retry_ms: 250}} = SSE.parse(state, "data: b\n\n")
  end

  test "a malformed or negative retry hint leaves the previous one" do
    {_, state} = SSE.parse(SSE.new(), "retry: 900\ndata: a\n\n")
    assert {["b"], %SSE{retry_ms: 900}} = SSE.parse(state, "retry: soon\ndata: b\n\n")
    assert {["c"], %SSE{retry_ms: 900}} = SSE.parse(state, "retry: -1\ndata: c\n\n")
  end

  test "flush keeps the retry hint of a buffered event" do
    {[], state} = SSE.parse(SSE.new(), "retry: 900\ndata: tail")
    assert {["tail"], %SSE{retry_ms: 900}} = SSE.flush(state)
  end

  test "raises when a pending event exceeds the buffer cap" do
    chunk = String.duplicate("x", 100_000) <> "\n"

    assert_raise LlmCall.SSE.Error, ~r/exceeded .* bytes/, fn ->
      Enum.reduce(1..20, SSE.new(), fn _, acc ->
        {_, state} = SSE.parse(acc, chunk)
        state
      end)
    end
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

  test "a CRLF split across chunks is normalised" do
    {first, state} = SSE.parse(SSE.new(), "data: [DONE]\r")
    assert first == []

    assert {["[DONE]"], _state} = SSE.parse(state, "\n\r\n")
  end

  test "a CRLF split across chunks does not split a multi-line data event" do
    {first, state} = SSE.parse(SSE.new(), "data: one\r")
    assert first == []
    assert %SSE{buffer: "data: one\n", cr_pending?: true} = state

    assert {["one\ntwo"], %SSE{buffer: "", cr_pending?: false}} =
             SSE.parse(state, "\ndata: two\r\n\r\n")
  end

  test "a CR-only terminator does not leave a pending CR behind" do
    {[], state} = SSE.parse(SSE.new(), "data: a\r")
    assert {["a"], %SSE{buffer: "", cr_pending?: false}} = SSE.parse(state, "\r")
  end

  test "an empty data line is not a payload" do
    assert {[], _state} = SSE.parse(SSE.new(), "data:\n\n")
  end

  test "normalises CRLF" do
    assert {["a"], _state} = SSE.parse(SSE.new(), "data: a\r\n\r\n")
  end

  test "normalises CR-only line endings" do
    assert {["a"], _state} = SSE.parse(SSE.new(), "data: a\r\r")
  end
end
