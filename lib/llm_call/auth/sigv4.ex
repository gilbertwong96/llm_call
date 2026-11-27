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

  `LlmCall.EncodedRequest.path` is signed **re-encoded**, not verbatim. SigV4's
  canonical URI is the URI-encoded path, and for every service except S3 that means
  encoding the bytes a request would carry — so a path segment a codec wrote as
  `%3A` (a Bedrock model id's colon) is canonicalised to `%253A`. Signing it verbatim
  is the mistake that only a real endpoint reports, as a signature mismatch, and it
  was found by comparing against botocore rather than by reasoning. A codec still
  percent-encodes its path, so the URL is what the provider expected.

  The query string is encoded here instead: `URI.encode_query/1` writes a space as
  `+` where SigV4 requires `%20`, and the canonical form is sorted after encoding.
  """

  alias LlmCall.Error
  alias LlmCall.HTTP.Request

  @algorithm "AWS4-HMAC-SHA256"
  @terminator "aws4_request"
  @hash_algorithm :sha256
  @replaced_headers ["host", "x-amz-date", "x-amz-security-token", "authorization"]

  @doc """
  Signs `request` and returns it carrying `host`, `x-amz-date` and `authorization`.

  Options: `service:`, `region:`, `credentials:` (a map with `:access_key_id` and
  `:secret_access_key`, and optionally `:session_token` and `:expiration`), `query:`
  (the merged query map) and `now:`.
  """
  @spec sign(Request.t(), keyword()) :: {:ok, Request.t()} | {:error, Error.t()}
  def sign(%Request{} = request, opts) do
    with :ok <- validate_url(request.url),
         {:ok, credentials} <- credentials(opts),
         :ok <- validate_path(request.url),
         :ok <- validate_query(Keyword.get(opts, :query, %{})) do
      {:ok, signed(request, opts, credentials)}
    end
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        validate_host(host)

      _uri ->
        invalid("sigv4: request URL must be absolute; it has no host")
    end
  end

  defp validate_host(host) do
    if ascii?(host),
      do: :ok,
      else:
        invalid(
          "sigv4: host must be ASCII; supply the punycode form (xn--) for an " <>
            "internationalized domain, for example with :idna.encode/1 from {:idna, \"~> 8.0\"}"
        )
  end

  defp validate_query(query) when is_map(query) do
    case Enum.find(query, fn {_key, value} -> not scalar?(value) end) do
      nil ->
        :ok

      {key, _value} ->
        invalid(
          "sigv4: query value for #{inspect(key)} must be a string, atom, number or boolean"
        )
    end
  end

  defp validate_query(_query), do: invalid("sigv4: query must be a map")

  defp scalar?(value), do: is_binary(value) or is_atom(value) or is_number(value)

  defp signed(%Request{} = request, opts, credentials) do
    service = Keyword.fetch!(opts, :service)
    region = Keyword.fetch!(opts, :region)
    query = Keyword.get(opts, :query, %{})

    uri = URI.parse(request.url)
    utc = utc_naive(opts[:now] || DateTime.utc_now())
    amz_date = Calendar.strftime(utc, "%Y%m%dT%H%M%SZ")
    date = Calendar.strftime(utc, "%Y%m%d")
    scope = Enum.join([date, region, service, @terminator], "/")

    headers =
      request.headers
      |> Enum.reject(fn {name, _value} -> String.downcase(name) in @replaced_headers end)
      |> Kernel.++([{"host", host(uri)}, {"x-amz-date", amz_date}])
      |> Kernel.++(token_header(credentials.session_token))

    {signed_names, canonical_headers} = canonical_headers(headers)
    canonical_query = canonical_query(query)

    canonical_request =
      Enum.join(
        [
          request.method |> to_string() |> String.upcase(),
          canonical_uri(uri.path || "/"),
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

    %{
      request
      | url: URI.to_string(%{uri | query: absent(canonical_query)}),
        headers: headers ++ [{"authorization", authorization}]
    }
  end

  defp token_header(nil), do: []
  defp token_header(token), do: [{"x-amz-security-token", token}]

  defp credentials(opts) do
    raw = Keyword.get(opts, :credentials)
    now = opts[:now] || DateTime.utc_now()

    with {:ok, access_key_id} <- credential_field(raw, :access_key_id),
         {:ok, secret_access_key} <- credential_field(raw, :secret_access_key),
         {:ok, session_token} <- session_token(raw),
         :ok <- expiration(raw, now) do
      {:ok,
       %{
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         session_token: session_token
       }}
    end
  end

  defp credential_field(credentials, key) when is_map(credentials) do
    case Map.get(credentials, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> invalid("sigv4: credentials require a non-empty #{inspect(key)}")
    end
  end

  defp credential_field(_credentials, key) do
    invalid("sigv4: credentials require a non-empty #{inspect(key)}")
  end

  defp session_token(credentials) do
    case Map.get(credentials, :session_token) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      token when is_binary(token) -> {:ok, token}
      _token -> invalid("sigv4: credentials session_token must be a string")
    end
  end

  defp expiration(credentials, now) do
    case Map.get(credentials, :expiration) do
      nil ->
        :ok

      %DateTime{} = expiration ->
        if DateTime.compare(expiration, now) == :gt,
          do: :ok,
          else: invalid("sigv4: credentials are expired")

      _expiration ->
        invalid("sigv4: credentials expiration must be a DateTime")
    end
  end

  defp validate_path(url) do
    path = URI.parse(url).path || "/"

    cond do
      String.contains?(path, " ") ->
        invalid("sigv4: request path must be percent-encoded; it contains a space")

      String.contains?(url, "#") ->
        invalid(~s(sigv4: request path must be percent-encoded; it contains "#"))

      not ascii?(path) ->
        invalid("sigv4: request path must be percent-encoded; it contains a non-ASCII byte")

      true ->
        :ok
    end
  end

  defp utc_naive(%DateTime{} = now) do
    offset = now.utc_offset + now.std_offset
    now |> DateTime.to_naive() |> NaiveDateTime.add(-offset, :second)
  end

  defp ascii?(string), do: string |> :binary.bin_to_list() |> Enum.all?(&(&1 < 128))

  defp invalid(message), do: {:error, %Error{kind: :validation, message: message}}

  defp canonical_headers(headers) do
    selected =
      headers
      |> Enum.map(fn {name, value} -> {String.downcase(name), normalize(value)} end)
      |> Enum.filter(&signed_header?/1)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort_by(&elem(&1, 0))

    {Enum.map_join(selected, ";", &elem(&1, 0)),
     selected
     |> Enum.flat_map(fn {name, value} -> [name, ":", value, "\n"] end)
     |> IO.iodata_to_binary()}
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
    |> Enum.map(fn {name, value} -> [name, "=", value] end)
    |> Enum.intersperse("&")
    |> IO.iodata_to_binary()
  end

  defp uri_encode(value) do
    value
    |> to_string()
    |> :binary.bin_to_list()
    |> Enum.map_join(&encode_byte/1)
  end

  # Every service but S3 canonicalises the path this way: encode each byte of the
  # path as it appears, `/` excepted. A `%` that is already there becomes `%25`, which
  # is what makes a pre-encoded segment sign correctly.
  defp canonical_uri(path) do
    path
    |> :binary.bin_to_list()
    |> Enum.map_join(fn
      ?/ -> "/"
      byte -> encode_byte(byte)
    end)
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
    authority = format_host(host)

    if is_nil(port) or default_port?(scheme, port),
      do: authority,
      else: authority <> ":" <> Integer.to_string(port)
  end

  defp format_host(host) do
    if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
  end

  defp default_port?("http", 80), do: true
  defp default_port?("https", 443), do: true
  defp default_port?(_scheme, _port), do: false

  defp absent(""), do: nil
  defp absent(query), do: query
end
