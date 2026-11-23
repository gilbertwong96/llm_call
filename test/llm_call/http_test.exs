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

  describe "build_url/3" do
    test "keeps the base path and appends the request path" do
      assert HTTP.build_url("https://api.example.test/openai", "/v1/chat/completions") ==
               "https://api.example.test/openai/v1/chat/completions"
    end

    test "never doubles a slash at the join" do
      assert HTTP.build_url("https://api.example.test/openai/", "/v1/chat") ==
               "https://api.example.test/openai/v1/chat"

      assert HTTP.build_url("https://api.example.test", "/v1/chat") ==
               "https://api.example.test/v1/chat"

      assert HTTP.build_url("https://api.example.test/", "/v1/chat") ==
               "https://api.example.test/v1/chat"
    end

    test "sets the encoded query on the URI instead of the path" do
      assert HTTP.build_url(
               "https://api.example.test/openai",
               "/v1/chat",
               "api-version=2024-02-01"
             ) ==
               "https://api.example.test/openai/v1/chat?api-version=2024-02-01"

      assert HTTP.build_url("https://api.example.test/openai", "/v1/chat", nil) ==
               "https://api.example.test/openai/v1/chat"
    end

    test "an empty query does not leave a trailing question mark" do
      assert HTTP.build_url("https://api.example.test/openai", "/v1/chat", "") ==
               "https://api.example.test/openai/v1/chat"
    end

    test "keeps userinfo, port and scheme, and drops a fragment" do
      assert HTTP.build_url("https://user:pass@host:8443/openai#frag", "/v1/chat") ==
               "https://user:pass@host:8443/openai/v1/chat"
    end

    test "accepts a parsed URI so a transport can change the scheme first" do
      base = URI.parse("http://api.example.test/openai")
      base = %{base | scheme: "ws"}

      assert HTTP.build_url(base, "/v1/responses", "GroupId=1") ==
               "ws://api.example.test/openai/v1/responses?GroupId=1"
    end
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

  describe "transport raises become typed errors" do
    # Finch calls `module.select(entries, state)` (or the fun) only when a pool
    # name maps to several entries, so this needs count: 2. Without the rescue in
    # request/2 and stream/4 the raise reaches the caller instead.
    defp multi_pool do
      name = :"llm_call_pool_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: name, pools: %{default: [count: 2, size: 1]}})
      name
    end

    test "request/2 returns {:error, {:exception, message}} instead of raising" do
      TestHTTP.put_events([{:status, 200}, {:data, "{}"}])
      name = multi_pool()
      boom = fn _entries, _state -> raise "strategy exploded" end
      request = Request.post(TestHTTP.url() <> "/v1/x", [], "{}", 5_000)

      assert {:error, {:exception, "strategy exploded"}} =
               HTTP.request(request, name: name, pool_strategy: {boom, nil})
    end

    test "stream/4 returns {:error, {:exception, message}} instead of raising" do
      name = multi_pool()
      boom = fn _entries, _state -> raise "strategy exploded" end
      request = Request.post(TestHTTP.url() <> "/v1/x", [], "{}", 5_000)

      assert {:error, {:exception, "strategy exploded"}} =
               HTTP.stream(request, [], fn event, acc -> {:cont, [event | acc]} end,
                 name: name,
                 pool_strategy: {boom, nil}
               )
    end

    test "a strategy fun that exits is reported, not propagated" do
      name = multi_pool()
      exiter = fn _entries, _state -> exit(:strategy_gone) end
      request = Request.post(TestHTTP.url() <> "/v1/x", [], "{}", 5_000)

      assert {:error, {:exception, message}} =
               HTTP.request(request, name: name, pool_strategy: {exiter, nil})

      assert message =~ "transport exited"
    end
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

  test "valid_headers?/1 rejects CRLF injection" do
    refute HTTP.valid_headers?([{"x-test", "ok\r\nInjected: yes"}])
    refute HTTP.valid_headers?([{"x\r\nInjected", "ok"}])
    assert HTTP.valid_headers?([{"x-test", "ok"}])
    assert HTTP.valid_headers?(nil)
  end

  test "valid_headers?/1 rejects non-token header names and bad merge input" do
    refute HTTP.valid_headers?([{"bad name", "v"}])
    refute HTTP.valid_headers?([{"bad:name", "v"}])
    refute HTTP.valid_headers?([{"x", "v\r\nInjected: yes"}])
    assert HTTP.valid_headers?([{"x-test", ""}])

    assert_raise ArgumentError, ~r/headers/, fn ->
      HTTP.merge_headers([["bad"]])
    end
  end

  test "retry_after_ms/1 parses delta-seconds and rejects malformed values" do
    assert HTTP.retry_after_ms([{"Retry-After", "5"}]) == 5_000
    assert HTTP.retry_after_ms([{"retry-after", "soon"}]) == nil
    assert HTTP.retry_after_ms([{"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}]) == 0
    assert HTTP.retry_after_ms([]) == nil
  end

  test "retryable_status?/1 is the one status rule" do
    for status <- [408, 425, 429, 500, 502, 503, 504] do
      assert LlmCall.Error.retryable_status?(status), "#{status} must be retryable"
    end

    for status <- [400, 401, 403, 404, 409, 413, 422, nil] do
      refute LlmCall.Error.retryable_status?(status), "#{inspect(status)} must not be"
    end
  end

  test "retry_after_ms/1 tolerates a non-list argument" do
    assert HTTP.retry_after_ms(nil) == nil
    assert HTTP.retry_after_ms(%{"retry-after" => "5"}) == nil
  end

  test "there is one transport module" do
    assert Code.ensure_loaded?(HTTP)
    assert function_exported?(HTTP, :request, 2)
    assert function_exported?(HTTP, :stream, 4)
    assert %Request{}.__struct__ == HTTP.Request
  end
end
