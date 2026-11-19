defmodule LlmCall.HTTPTest do
  use ExUnit.Case, async: true

  alias LlmCall.HTTP
  alias LlmCall.HTTP.Request
  alias LlmCall.TestHTTPServer, as: TestHTTP

  setup do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    :ok
  end

  test "request/2 returns status, headers and body" do
    TestHTTP.put_response(
      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: ~s({"ok":true})
       }}
    )

    request =
      Request.post(
        TestHTTP.url() <> "/v1/x",
        [{"content-type", "application/json"}],
        "{}",
        5_000
      )

    assert {:ok, %{status: 200, headers: headers, body: body}} = HTTP.request(request)
    assert body == ~s({"ok":true})
    assert {"content-type", "application/json"} in headers
  end

  test "stream/4 delivers the status before any data" do
    TestHTTP.put_events([{:status, 200}, {:data, "data: one\n\n"}])

    request = Request.post(TestHTTP.url() <> "/v1/x", [], "{}", 5_000)

    assert {:ok, events} =
             HTTP.stream(request, [], fn event, acc -> {:cont, [event | acc]} end, [])

    assert [{:status, 200} | _rest] = Enum.reverse(events)
    assert Enum.any?(events, &match?({:data, "data: one\n\n"}, &1))
  end

  test "a non-2xx status is reported on the stream" do
    TestHTTP.put_events([{:status, 401}, {:data, ~s({"error":{"message":"nope"}})}])

    request = Request.post(TestHTTP.url() <> "/v1/x", [], "{}", 5_000)

    assert {:ok, events} =
             HTTP.stream(request, [], fn event, acc -> {:cont, [event | acc]} end, [])

    assert {:status, 401} in events
  end

  test "retry_after_ms/1 parses delta-seconds and rejects malformed values" do
    assert HTTP.retry_after_ms([{"Retry-After", "5"}]) == 5_000
    assert HTTP.retry_after_ms([{"retry-after", "soon"}]) == nil
    assert HTTP.retry_after_ms([{"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}]) == 0
    assert HTTP.retry_after_ms([]) == nil
  end

  test "there is one transport module" do
    assert Code.ensure_loaded?(HTTP)
    assert function_exported?(HTTP, :request, 2)
    assert function_exported?(HTTP, :stream, 4)
    assert %Request{}.__struct__ == HTTP.Request
  end
end
