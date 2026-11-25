defmodule LlmCall.TestSigV4Provider do
  @moduledoc "Provider used by the SigV4 wiring tests."

  use LlmCall.Provider,
    base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
    auth: {:sigv4, service: "bedrock", region: "us-east-1"},
    codecs: [chat: LlmCall.TestCodec.Fake]
end

defmodule LlmCall.SigV4ProviderTest do
  use ExUnit.Case, async: true

  alias LlmCall.TestHTTPServer, as: TestHTTP
  alias LlmCall.TestSigV4Provider

  @credentials %{access_key_id: "AKID", secret_access_key: "S"}

  setup do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    :ok
  end

  defp client(opts \\ []) do
    TestSigV4Provider.client(
      Keyword.merge([base_url: TestHTTP.url(), credentials: @credentials], opts)
    )
  end

  defp request do
    %LlmCall.Request{
      model: "fake-1",
      messages: [%LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "hi"}]}]
    }
  end

  defp header(sent, name) do
    Enum.find_value(sent.headers, fn {key, value} -> if key == name, do: value end)
  end

  defp respond do
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"text":"pong"})}})
  end

  test "a SigV4 client needs credentials, not an api_key" do
    assert_raise ArgumentError, ~r/credentials/, fn -> TestSigV4Provider.client([]) end

    assert TestSigV4Provider.client(credentials: @credentials).signer ==
             %{service: "bedrock", region: "us-east-1"}
  end

  test "complete/3 signs the request it sends" do
    respond()

    assert {:ok, _response} = LlmCall.complete(client(), request())

    assert [sent] = TestHTTP.requests()
    assert header(sent, "x-amz-date") =~ ~r/^\d{8}T\d{6}Z$/
    assert header(sent, "authorization") =~ "Credential=AKID/"
    assert header(sent, "authorization") =~ "/us-east-1/bedrock/aws4_request"
  end

  test "stream/3 signs too" do
    TestHTTP.put_events([
      {:status, 200},
      {:data, "data: {\"delta\":\"hi\"}\n\n"},
      {:data, "data: [DONE]\n\n"}
    ])

    assert {:ok, stream} = LlmCall.stream(client(), request())
    assert [_event | _rest] = Enum.to_list(stream)

    assert [sent] = TestHTTP.requests()
    assert header(sent, "authorization") =~ "Signature="
  end

  test "region: overrides the declaration" do
    respond()

    assert {:ok, _response} = LlmCall.complete(client(region: "eu-west-1"), request())

    assert [sent] = TestHTTP.requests()
    assert header(sent, "authorization") =~ "/eu-west-1/bedrock/aws4_request"
  end

  test "a base_url override keeps the declared region" do
    respond()

    assert {:ok, _response} = LlmCall.complete(client(), request())

    assert [sent] = TestHTTP.requests()
    assert header(sent, "authorization") =~ "/us-east-1/bedrock/aws4_request"
  end

  test "a credentials function is called once per request" do
    parent = self()

    credentials = fn ->
      send(parent, :credentials)
      @credentials
    end

    respond()
    assert {:ok, _response} = LlmCall.complete(client(credentials: credentials), request())

    respond()
    assert {:ok, _response} = LlmCall.complete(client(credentials: credentials), request())

    assert_received :credentials
    assert_received :credentials
    refute_received :credentials
  end

  test "region: on a provider without :sigv4 raises" do
    assert_raise ArgumentError, ~r/region is only used by :sigv4 auth/, fn ->
      LlmCall.TestProvider.client(api_key: "secret", region: "us-east-1")
    end
  end

  test "a path prefix and a non-default port are part of what is signed" do
    respond()

    client = client(base_url: TestHTTP.url() <> "/aws")
    assert {:ok, _response} = LlmCall.complete(client, request())

    assert [sent] = TestHTTP.requests()
    uri = URI.parse(TestHTTP.url())
    assert sent.path == "/aws/fake"
    assert header(sent, "host") == "#{uri.host}:#{uri.port}"
    assert header(sent, "authorization") =~ "SignedHeaders=host;x-amz-date"
  end
end
