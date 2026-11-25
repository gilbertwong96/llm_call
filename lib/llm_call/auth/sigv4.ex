defmodule LlmCall.Auth.SigV4 do
  @moduledoc """
  AWS Signature Version 4.

  AWS signs requests instead of issuing bearer tokens, and the reason matters to
  anyone implementing it: the secret access key never travels. A signature proves
  possession, binds the method, path, query, headers and a hash of the body to one
  date, region and service, and expires with the timestamp in its credential
  scope. Presigned URLs and STS temporary credentials are built on that; a bearer
  token gives all of it up.

  The cost is placement. A signature covers the exact bytes that go on the wire,
  so it cannot be a header a caller adds in advance: it is computed after the
  request body has been serialized, which is why signing sits beside the transport
  and not inside a codec.

  `LlmCall.EncodedRequest.path` is signed verbatim, because a codec has already
  percent-encoded it. The query string is encoded here instead: `URI.encode_query/1`
  writes a space as `+` where SigV4 requires `%20`, and the canonical form is
  sorted after encoding.
  """

  alias LlmCall.HTTP.Request

  @algorithm "AWS4-HMAC-SHA256"
  @terminator "aws4_request"
  @hash_algorithm :sha256
  @replaced_headers ["host", "x-amz-date", "authorization"]

  @doc """
  Signs `request` and returns it carrying `host`, `x-amz-date` and `authorization`.

  Options: `service:`, `region:`, `credentials:` (a map with `:access_key_id` and
  `:secret_access_key`), `query:` (the merged query map) and `now:`.
  """
  @spec sign(Request.t(), keyword()) :: {:ok, Request.t()}
  def sign(%Request{} = request, opts) do
    service = Keyword.fetch!(opts, :service)
    region = Keyword.fetch!(opts, :region)
    credentials = Keyword.fetch!(opts, :credentials)
    query = Keyword.get(opts, :query, %{})

    uri = URI.parse(request.url)
    now = opts[:now] || DateTime.utc_now()
    amz_date = amz_date(now)
    date = Calendar.strftime(now, "%Y%m%d")
    scope = Enum.join([date, region, service, @terminator], "/")

    headers =
      request.headers
      |> Enum.reject(fn {name, _value} -> String.downcase(name) in @replaced_headers end)
      |> Kernel.++([{"host", host(uri)}, {"x-amz-date", amz_date}])

    {signed_names, canonical_headers} = canonical_headers(headers)
    canonical_query = canonical_query(query)

    canonical_request =
      Enum.join(
        [
          request.method |> to_string() |> String.upcase(),
          uri.path || "/",
          canonical_query,
          canonical_headers,
          signed_names,
          sha256_hex(request.body || "")
        ],
        "\n"
      )

    signature_hex =
      signature_hex(canonical_request, amz_date, scope, credentials, date, region, service)

    authorization =
      "#{@algorithm} Credential=#{credentials.access_key_id}/#{scope}, " <>
        "SignedHeaders=#{signed_names}, Signature=#{signature_hex}"

    {:ok,
     %{
       request
       | url: URI.to_string(%{uri | query: absent(canonical_query)}),
         headers: headers ++ [{"authorization", authorization}]
     }}
  end

  defp canonical_headers(headers) do
    selected =
      headers
      |> Enum.map(fn {name, value} -> {String.downcase(name), normalize(value)} end)
      |> Enum.filter(&signed_header?/1)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort_by(&elem(&1, 0))

    {Enum.map_join(selected, ";", &elem(&1, 0)),
     Enum.map_join(selected, "", fn {name, value} -> name <> ":" <> value <> "\n" end)}
  end

  defp signed_header?({"host", _value}), do: true
  defp signed_header?({"content-type", _value}), do: true
  defp signed_header?({name, _value}), do: String.starts_with?(name, "x-amz-")

  defp normalize(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp canonical_query(query) do
    query
    |> Enum.map(fn {name, value} -> {uri_encode(name), uri_encode(value)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {name, value} -> name <> "=" <> value end)
  end

  defp uri_encode(value) do
    value
    |> to_string()
    |> :binary.bin_to_list()
    |> Enum.map_join(&encode_byte/1)
  end

  defp encode_byte(byte) when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9, do: <<byte>>
  defp encode_byte(byte) when byte in [?-, ?_, ?., ?~], do: <<byte>>
  defp encode_byte(byte), do: "%" <> Base.encode16(<<byte>>)

  defp signature_hex(canonical_request, amz_date, scope, credentials, date, region, service) do
    string_to_sign = Enum.join([@algorithm, amz_date, scope, sha256_hex(canonical_request)], "\n")

    ("AWS4" <> credentials.secret_access_key)
    |> hmac(date)
    |> hmac(region)
    |> hmac(service)
    |> hmac(@terminator)
    |> hmac(string_to_sign)
    |> Base.encode16(case: :lower)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, @hash_algorithm, key, data)

  defp sha256_hex(data), do: Base.encode16(:crypto.hash(@hash_algorithm, data), case: :lower)

  defp host(%URI{host: host, scheme: scheme, port: port}) do
    if is_nil(port) or default_port?(scheme, port),
      do: host,
      else: host <> ":" <> Integer.to_string(port)
  end

  defp default_port?("http", 80), do: true
  defp default_port?("https", 443), do: true
  defp default_port?(_scheme, _port), do: false

  defp amz_date(now), do: Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

  defp absent(""), do: nil
  defp absent(query), do: query
end
