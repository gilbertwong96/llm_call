defmodule LlmCall.MediaConformance do
  @moduledoc """
  Fixture-based assertions for media codec authors.

  Test support, not a runtime dependency. Every function returns `:ok` or raises
  an `ExUnit.AssertionError` naming the failed expectation.

      test "my media codec conforms" do
        MediaConformance.assert_info(MyCodec)
        MediaConformance.assert_submit_path(MyCodec, request, "/v1/my-images")
      end
  """

  import ExUnit.Assertions

  alias LlmCall.{Codec, Config, EncodedRequest, Error, MediaCapabilities}

  @credential_headers ["authorization", "x-api-key", "api-key"]

  @spec assert_info(module()) :: :ok
  def assert_info(codec) do
    info = codec.info()

    assert %Codec.Info{name: name, protocol: protocol, version: version, ir_version: 1} = info,
           "#{inspect(codec)}.info/0 must return %LlmCall.Codec.Info{} with ir_version 1"

    assert is_atom(name), "#{inspect(codec)}.info/0 name must be an atom"
    assert is_atom(protocol), "#{inspect(codec)}.info/0 protocol must be an atom"

    assert is_nil(version) or is_binary(version),
           "#{inspect(codec)}.info/0 version must be a string or nil"

    :ok
  end

  @spec assert_capabilities(module(), LlmCall.MediaRequest.t(), Config.t()) :: :ok
  def assert_capabilities(codec, request, config) do
    assert Code.ensure_loaded?(codec), "#{inspect(codec)} is not loaded"

    assert %MediaCapabilities{async: async} = codec.capabilities(request, config),
           "#{inspect(codec)}.capabilities/2 must return %LlmCall.MediaCapabilities{}"

    if async do
      assert function_exported?(codec, :decode_operation, 2),
             "#{inspect(codec)} declares async: true but does not export decode_operation/2"
    else
      refute function_exported?(codec, :decode_operation, 2),
             "#{inspect(codec)} declares async: false but exports decode_operation/2"
    end

    :ok
  end

  @spec assert_submit_path(module(), LlmCall.MediaRequest.t(), String.t()) :: :ok
  def assert_submit_path(codec, request, expected_path) do
    result = codec.encode_submit(request, %Config{})

    assert match?({:ok, %EncodedRequest{}}, result),
           "#{inspect(codec)}.encode_submit/2 must return {:ok, %LlmCall.EncodedRequest{}}, " <>
             "got: #{inspect(result)}"

    {:ok, %EncodedRequest{} = encoded} = result

    assert encoded.method == :post
    assert encoded.path == expected_path
    assert is_map(encoded.body)
    assert is_map(encoded.query)
    assert is_list(encoded.headers)

    names = Enum.map(encoded.headers, fn {name, _value} -> String.downcase(name) end)

    for forbidden <- @credential_headers do
      refute forbidden in names,
             "#{inspect(codec)} encoded request contains a credential header #{inspect(forbidden)}"
    end

    :ok
  end

  @spec assert_capture_raw(module(), LlmCall.wire_value()) :: :ok
  def assert_capture_raw(codec, provider_payload) do
    for {capture, expected} <- [none: nil, response: provider_payload, all: provider_payload] do
      case codec.decode_submit(provider_payload, %Config{capture_raw: capture}) do
        {:ok, %{raw: raw}} ->
          assert raw == expected,
                 "#{inspect(codec)} raw must be #{inspect(expected)} with " <>
                   "capture_raw: #{inspect(capture)}, got: #{inspect(raw)}"

        other ->
          flunk(
            "#{inspect(codec)}.decode_submit/2 must succeed with " <>
              "capture_raw: #{inspect(capture)}, got: #{inspect(other)}"
          )
      end
    end

    :ok
  end

  @spec assert_sync_rejects_operation(module()) :: :ok
  def assert_sync_rejects_operation(codec) do
    assert {:error, %Error{kind: :validation}} =
             LlmCall.decode_operation(codec, %{}, %Config{}),
           "#{inspect(codec)} is synchronous, so decode_operation/3 must be a validation error"

    :ok
  end
end
