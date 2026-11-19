defmodule LlmCall.TransportReasonTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Content, Error, Message, Request}

  defp request do
    %Request{model: "m", messages: [%Message{role: :user, content: [%Content.Text{text: "x"}]}]}
  end

  test "an unknown pool renders as a stable message" do
    client =
      LlmCall.TestProvider.client(
        api_key: "k",
        base_url: "http://127.0.0.1:1",
        http_opts: [name: LlmCall.NoSuchPool]
      )

    assert {:error, %Error{kind: :transport, message: "unknown pool: LlmCall.NoSuchPool"}} =
             LlmCall.complete(client, request())
  end

  test "a connection failure renders the Mint message, not the struct" do
    client = LlmCall.TestProvider.client(api_key: "k", base_url: "http://127.0.0.1:1")

    assert {:error, %Error{kind: :transport, message: message}} =
             LlmCall.complete(client, request())

    assert message == "transport error: connection refused"
  end
end
