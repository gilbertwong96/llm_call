defmodule LlmCall.Auth.SigV4VectorsTest do
  @moduledoc """
  Replays requests botocore signed, and asserts the same `Authorization` header.

  The published `ListUsers` vector in `LlmCall.Auth.SigV4Test` proves the algorithm for
  a `/` path. Path canonicalisation is the part that vector cannot reach, and it is
  where a wrong signature is invisible until a real endpoint answers 403.

  `test/support/fixtures/sigv4/vectors.json` is botocore's own output, committed
  verbatim: `generate.py` beside it records the version and the call. botocore is not
  a dependency — the file is the oracle.
  """
  use ExUnit.Case, async: true

  alias LlmCall.Auth.SigV4
  alias LlmCall.HTTP.Request

  @vectors_path Path.expand("../../support/fixtures/sigv4/vectors.json", __DIR__)

  @static %{
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
  }

  @session Map.put(
             @static,
             :session_token,
             "AQoDYXdzEJr+EXAMPLE-TOKEN"
           )
           |> Map.put(:access_key_id, "TESTIOSFODNN7EXAMPLE")

  setup_all do
    {:ok, vectors: @vectors_path |> File.read!() |> JSON.decode!()}
  end

  test "every botocore vector signs the same way", %{vectors: vectors} do
    assert Enum.count(vectors) == 8

    for vector <- vectors do
      assert_authorization(vector)
    end
  end

  # One named case, so a failure says which canonicalisation rule broke rather than
  # "somewhere in the list".
  for name <- ~w(converse_colon_encoded converse_arn_model path_unreserved get_empty_body
                 query_encoding_and_order session_token header_value_normalised utf8_body) do
    test "#{name} matches botocore", %{vectors: vectors} do
      vector = Enum.find(vectors, &(&1["name"] == unquote(name)))
      assert vector, "the fixture has no vector named #{unquote(name)}"
      assert_authorization(vector)
    end
  end

  defp assert_authorization(vector) do
    request = %Request{
      method: String.to_atom(String.downcase(vector["method"])),
      url: vector["url"],
      headers: Enum.map(vector["headers"], fn {name, value} -> {name, value} end),
      body: vector["body"]
    }

    {:ok, now, _offset} = DateTime.from_iso8601(amz_date_iso8601(vector["amz_date"]))

    assert {:ok, signed} =
             SigV4.sign(request,
               service: vector["service"],
               region: vector["region"],
               credentials: credentials(vector["credentials"]),
               query: vector["query"],
               now: now
             )

    assert header(signed, "authorization") == vector["authorization"],
           """
           #{vector["name"]}: signature differs from botocore.

           botocore canonical request:

           #{vector["canonical_request"]}
           """

    # The host header is what the canonical request covers, so a mismatch there would
    # explain a signature mismatch.
    assert header(signed, "host") == URI.parse(vector["url"]).host
  end

  # `20261127T025549Z` -> `2026-11-27T02:55:49Z`
  defp amz_date_iso8601(amz_date) do
    <<year::binary-4, month::binary-2, day::binary-2, "T", hour::binary-2, minute::binary-2,
      second::binary-2, "Z">> = amz_date

    Enum.join([year, month, day], "-") <>
      "T" <>
      Enum.join([hour, minute, second], ":") <> "Z"
  end

  defp credentials("session"), do: @session
  defp credentials(_static), do: @static

  defp header(%Request{headers: headers}, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end
end
