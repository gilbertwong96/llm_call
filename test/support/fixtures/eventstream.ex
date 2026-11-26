defmodule LlmCall.Fixtures.EventStream do
  @moduledoc """
  `application/vnd.amazon.eventstream` frames, produced by somebody else.

  The oracle is `@smithy/eventstream-codec@4.5.2` — the encoder the AWS SDK for
  JavaScript uses against Bedrock. Regenerate with
  `test/support/fixtures/eventstream/generate.mjs`, which records the exact header
  set behind each frame; never edit the base64 by hand.

  A hand-built fixture could only confirm what the decoder already believed, and a
  wrong header length or CRC would be wrong in both encoder and decoder. These
  bytes come from an independent implementation, so agreement means something.
  """

  @frames %{
    message_start:
      "AAAAdgAAAFKW1freDTptZXNzYWdlLXR5cGUHAAVldmVudAs6ZXZlbnQtdHlwZQcADG1lc3NhZ2VTdGFydA06Y29udGVudC10eXBlBwAQYXBwbGljYXRpb24vanNvbnsicm9sZSI6ImFzc2lzdGFudCJ9HMa+GA==",
    content_block_delta:
      "AAAAlwAAAFfzC+A+DTptZXNzYWdlLXR5cGUHAAVldmVudAs6ZXZlbnQtdHlwZQcAEWNvbnRlbnRCbG9ja0RlbHRhDTpjb250ZW50LXR5cGUHABBhcHBsaWNhdGlvbi9qc29ueyJkZWx0YSI6eyJ0ZXh0IjoiSGVsbG8ifSwiY29udGVudEJsb2NrSW5kZXgiOjB9L+w3XQ==",
    exception:
      "AAAAkAAAAGGOkam3DTptZXNzYWdlLXR5cGUHAAlleGNlcHRpb24POmV4Y2VwdGlvbi10eXBlBwATdGhyb3R0bGluZ0V4Y2VwdGlvbg06Y29udGVudC10eXBlBwAQYXBwbGljYXRpb24vanNvbnsibWVzc2FnZSI6IlRvbyBtYW55IHJlcXVlc3RzIn2da2IR",
    message_stop:
      "AAAAegAAAFHKLEZlDTptZXNzYWdlLXR5cGUHAAVldmVudAs6ZXZlbnQtdHlwZQcAC21lc3NhZ2VTdG9wDTpjb250ZW50LXR5cGUHABBhcHBsaWNhdGlvbi9qc29ueyJzdG9wUmVhc29uIjoiZW5kX3R1cm4ifT3DO/o=",
    metadata:
      "AAAAtgAAAE5rwU5KDTptZXNzYWdlLXR5cGUHAAVldmVudAs6ZXZlbnQtdHlwZQcACG1ldGFkYXRhDTpjb250ZW50LXR5cGUHABBhcHBsaWNhdGlvbi9qc29ueyJ1c2FnZSI6eyJpbnB1dFRva2VucyI6Mywib3V0cHV0VG9rZW5zIjo1LCJ0b3RhbFRva2VucyI6OH0sIm1ldHJpY3MiOnsibGF0ZW5jeU1zIjoxMjB9fSHIgqs=",
    empty: "AAAAEAAAAAAFwkjrfZjI/w==",
    every_header_type:
      "AAAAnwAAAIjVF2S6CWJvb2xfdHJ1ZQAKYm9vbF9mYWxzZQEEYnl0ZQL5BXNob3J0A/7UB2ludGVnZXIE//7ukARsb25nBQAAAR9x+wTLBmJpbmFyeQYAAwD/fwZzdHJpbmcHAAZow6lsbG8JdGltZXN0YW1wCAAAAYvP5WgABHV1aWQJASNFZ4mrze8BI0VniavN73BheWxvYWQDmvT0",
    binary_payload: "AAAAJwAAABOSfW2jCzpldmVudC10eXBlBwAEYmxvYgD//oAID+aW",
    split_first_half: "AAAAawAAAEGK",
    split_second_half:
      "G+gzCzpldmVudC10eXBlBwARY29udGVudEJsb2NrRGVsdGENOmNvbnRlbnQtdHlwZQcAEGFwcGxpY2F0aW9uL2pzb257ImRlbHRhIjp7InRleHQiOiJzcGxpdCJ9fRYnV70="
  }

  @doc "The frame as bytes."
  @spec frame(atom()) :: binary()
  def frame(name), do: @frames |> Map.fetch!(name) |> Base.decode64!()
end
