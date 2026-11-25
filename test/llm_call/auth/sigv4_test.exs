defmodule LlmCall.Auth.SigV4Test do
  use ExUnit.Case, async: true

  alias LlmCall.Auth.SigV4
  alias LlmCall.Error
  alias LlmCall.HTTP.Request

  @credentials %{
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
  }

  defp header(%Request{headers: headers}, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  test "reproduces the signature AWS publishes for IAM ListUsers" do
    request = %Request{
      method: :get,
      url: "https://iam.amazonaws.com/",
      headers: [{"content-type", "application/x-www-form-urlencoded; charset=utf-8"}],
      body: ""
    }

    assert {:ok, signed} =
             SigV4.sign(request,
               service: "iam",
               region: "us-east-1",
               credentials: @credentials,
               query: %{"Action" => "ListUsers", "Version" => "2010-05-08"},
               now: ~U[2015-08-30 12:36:00Z]
             )

    assert header(signed, "host") == "iam.amazonaws.com"
    assert header(signed, "x-amz-date") == "20150830T123600Z"

    assert header(signed, "authorization") ==
             "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, " <>
               "SignedHeaders=content-type;host;x-amz-date, " <>
               "Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"

    assert signed.url == "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08"
  end

  defp sign!(url, request_overrides \\ [], sign_opts \\ []) do
    request =
      struct(
        %Request{
          method: :post,
          url: url,
          headers: [{"content-type", "application/json"}],
          body: "x"
        },
        request_overrides
      )

    opts =
      Keyword.merge(
        [
          service: "bedrock",
          region: "us-east-1",
          credentials: @credentials,
          query: %{},
          now: ~U[2026-11-24 00:00:00Z]
        ],
        sign_opts
      )

    {:ok, signed} = SigV4.sign(request, opts)
    signed
  end

  test "a space in a query value is encoded as %20, never as +" do
    signed = sign!("https://example.test/", [], query: %{"q" => "a b"})

    assert signed.url == "https://example.test/?q=a%20b"
  end

  test "query parameters are sorted after encoding" do
    signed = sign!("https://example.test/", [], query: %{"b" => "2", "a" => "1"})

    assert signed.url == "https://example.test/?a=1&b=2"
  end

  test "query names keep their case when sorted" do
    signed = sign!("https://example.test/", [], query: %{"A" => "1", "a" => "2"})

    assert signed.url == "https://example.test/?A=1&a=2"
  end

  test "a non-default port belongs to the host header" do
    signed = sign!("http://127.0.0.1:4566/aws/converse")

    assert header(signed, "host") == "127.0.0.1:4566"
    assert header(signed, "authorization") =~ "SignedHeaders=content-type;host;x-amz-date"
    assert URI.parse(signed.url).path == "/aws/converse"
  end

  test "header values are trimmed and internal whitespace is collapsed" do
    padded = sign!("https://example.test/", headers: [{"x-amz-meta-note", "  a   b  "}])
    plain = sign!("https://example.test/", headers: [{"x-amz-meta-note", "a b"}])

    assert header(padded, "authorization") == header(plain, "authorization")
    assert header(padded, "authorization") =~ "x-amz-meta-note"
  end

  test "the body participates in the signature and the digest is stable" do
    first = sign!("https://example.test/", body: "")
    second = sign!("https://example.test/", body: "")
    other = sign!("https://example.test/", body: "x")

    assert header(first, "authorization") == header(second, "authorization")
    refute header(first, "authorization") == header(other, "authorization")
  end

  test "a raw colon and a percent-encoded colon sign differently" do
    raw = sign!("https://example.test/model/a:b/converse")
    encoded = sign!("https://example.test/model/a%3Ab/converse")

    refute header(raw, "authorization") == header(encoded, "authorization")
    assert URI.parse(raw.url).path == "/model/a:b/converse"
    assert URI.parse(encoded.url).path == "/model/a%3Ab/converse"
  end

  test "signing an already signed request is idempotent" do
    once = sign!("https://example.test/model/m/converse")

    {:ok, twice} =
      SigV4.sign(once,
        service: "bedrock",
        region: "us-east-1",
        credentials: @credentials,
        query: %{},
        now: ~U[2026-11-24 00:00:00Z]
      )

    assert header(twice, "authorization") == header(once, "authorization")
    assert Enum.count(twice.headers, fn {name, _value} -> name == "host" end) == 1
  end

  test "a session token is sent and signed" do
    signed =
      sign!("https://example.test/model/m/converse", [],
        credentials: Map.put(@credentials, :session_token, "TOKEN")
      )

    assert header(signed, "x-amz-security-token") == "TOKEN"

    assert header(signed, "authorization") =~
             "SignedHeaders=content-type;host;x-amz-date;x-amz-security-token"
  end

  test "an empty session token is treated as absent" do
    signed =
      sign!("https://example.test/model/m/converse", [],
        credentials: Map.put(@credentials, :session_token, "")
      )

    refute header(signed, "x-amz-security-token")
    refute header(signed, "authorization") =~ "x-amz-security-token"
  end

  test "expired credentials fail before the request is built" do
    credentials = Map.put(@credentials, :expiration, ~U[2020-01-01 00:00:00Z])

    assert {:error, %Error{kind: :validation, message: message}} =
             SigV4.sign(signed_request(), sign_opts(credentials: credentials))

    assert message =~ "expired"
  end

  test "a missing credential key is named in the error" do
    assert {:error, %Error{kind: :validation, message: message}} =
             SigV4.sign(signed_request(), sign_opts(credentials: %{access_key_id: "AKID"}))

    assert message =~ ":secret_access_key"
  end

  test "a URL without a host is refused, not crashed on" do
    assert {:error, %Error{kind: :validation, message: message}} =
             SigV4.sign(signed_request("/relative/path"), sign_opts())

    assert message =~ "host"
  end

  test "an IPv6 host keeps its brackets in the host header" do
    signed = sign!("http://[::1]:4566/aws/converse")

    assert header(signed, "host") == "[::1]:4566"
  end

  test "a path the signer cannot sign verbatim is refused" do
    assert {:error, %Error{kind: :validation, message: message}} =
             SigV4.sign(signed_request("https://example.test/model/a b/converse"), sign_opts())

    assert message =~ "space"

    assert {:error, %Error{kind: :validation, message: unicode}} =
             SigV4.sign(signed_request("https://example.test/model/ü/converse"), sign_opts())

    assert unicode =~ "non-ASCII"

    assert {:error, %Error{kind: :validation, message: fragment}} =
             SigV4.sign(signed_request("https://example.test/model/a#frag/converse"), sign_opts())

    assert fragment =~ "#"
  end

  defp signed_request(url \\ "https://example.test/model/m/converse") do
    %Request{
      method: :post,
      url: url,
      headers: [{"content-type", "application/json"}],
      body: "x"
    }
  end

  defp sign_opts(overrides \\ []) do
    Keyword.merge(
      [
        service: "bedrock",
        region: "us-east-1",
        credentials: @credentials,
        query: %{},
        now: ~U[2026-11-24 00:00:00Z]
      ],
      overrides
    )
  end
end
