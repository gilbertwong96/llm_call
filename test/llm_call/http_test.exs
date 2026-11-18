defmodule LlmCall.HTTPTest do
  use ExUnit.Case, async: true

  alias LlmCall.HTTP
  alias LlmCall.HTTP.Finch, as: Adapter
  alias LlmCall.HTTP.Request

  defp serve(responses) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])

    {:ok, port} = :inet.port(listen)

    agent =
      spawn_link(fn ->
        Enum.each(responses, fn {status, body} -> accept_once(listen, status, body) end)
        :gen_tcp.close(listen)
      end)

    _ = agent
    {port, listen}
  end

  defp accept_once(listen, status, body) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

    response = [
      "HTTP/1.1 #{status} X\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]

    :ok = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  test "request/2 returns status, headers and body" do
    {port, _listen} = serve([{200, ~s({"ok":true})}])

    request =
      Request.post(
        "http://127.0.0.1:#{port}/v1/x",
        [{"content-type", "application/json"}],
        "{}",
        5_000
      )

    assert {:ok, %{status: 200, headers: headers, body: body}} = Adapter.request(request)
    assert body == ~s({"ok":true})
    assert {"content-type", "application/json"} in headers
  end

  test "stream/4 delivers the status before any data" do
    {port, _listen} = serve([{200, "data: one\n\n"}])

    request = Request.post("http://127.0.0.1:#{port}/v1/x", [], "{}", 5_000)

    assert {:ok, events} =
             Adapter.stream(request, [], fn event, acc -> {:cont, [event | acc]} end, [])

    assert [{:status, 200} | _rest] = Enum.reverse(events)
    assert Enum.any?(events, &match?({:data, "data: one\n\n"}, &1))
  end

  test "a non-2xx status is reported on the stream" do
    {port, _listen} = serve([{401, ~s({"error":{"message":"nope"}})}])

    request = Request.post("http://127.0.0.1:#{port}/v1/x", [], "{}", 5_000)

    assert {:ok, events} =
             Adapter.stream(request, [], fn event, acc -> {:cont, [event | acc]} end, [])

    assert {:status, 401} in events
  end

  test "the behaviour is replaceable by module" do
    Code.ensure_loaded?(LlmCall.HTTP.Test)
    assert function_exported?(LlmCall.HTTP.Test, :request, 2)
    assert function_exported?(LlmCall.HTTP.Test, :stream, 4)
    assert %Request{}.__struct__ == HTTP.Request
  end
end
