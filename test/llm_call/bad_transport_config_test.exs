defmodule LlmCall.BadTransportConfigTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Content, Error, HTTP, Message, Request}

  defp request do
    %Request{model: "m", messages: [%Message{role: :user, content: [%Content.Text{text: "x"}]}]}
  end

  defp encoded do
    %LlmCall.EncodedRequest{method: :get, path: "/asset"}
  end

  test "a Finch pool that is not running is a transport error, not a raise" do
    client =
      LlmCall.TestProvider.client(
        api_key: "k",
        base_url: "http://127.0.0.1:1",
        http_opts: [name: LlmCall.NoSuchPool]
      )

    assert {:error, %Error{kind: :transport, message: message}} =
             LlmCall.complete(client, request())

    assert message =~ "LlmCall.NoSuchPool"

    assert {:error, %Error{kind: :transport}} = LlmCall.execute(client, encoded())
    assert {:error, %Error{kind: :transport}} = LlmCall.fetch(client, encoded())
  end

  test "a stream with a missing pool raises HTTP.Error, not ArgumentError" do
    client =
      LlmCall.TestProvider.client(
        api_key: "k",
        base_url: "http://127.0.0.1:1",
        http_opts: [name: LlmCall.NoSuchPool]
      )

    assert {:ok, stream} = LlmCall.stream(client, request())

    exception = assert_raise HTTP.Error, fn -> Enum.to_list(stream) end
    assert %Error{kind: :transport, message: message} = HTTP.Error.error(exception)
    assert message =~ "LlmCall.NoSuchPool"
  end

  test "HTTP.request/2 reports a missing pool as an error tuple" do
    http_request = HTTP.Request.get("http://127.0.0.1:1/x", [], 100)

    assert {:error, {:unknown_pool, LlmCall.NoSuchPool}} =
             HTTP.request(http_request, name: LlmCall.NoSuchPool)
  end

  test "HTTP.stream/4 reports a missing pool as an error tuple" do
    http_request = HTTP.Request.get("http://127.0.0.1:1/x", [], 100)

    assert {:error, {:unknown_pool, LlmCall.NoSuchPool}} =
             HTTP.stream(http_request, :acc, fn _event, acc -> {:cont, acc} end,
               name: LlmCall.NoSuchPool
             )
  end
end
