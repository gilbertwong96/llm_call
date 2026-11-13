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

  alias LlmCall.{Codec, Config, Content, EncodedRequest, Error, Operation}
  alias LlmCall.Media.Capabilities, as: MediaCapabilities
  alias LlmCall.Media.Request, as: MediaRequest
  alias LlmCall.Media.Response, as: MediaResponse

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

  @spec assert_capabilities(module(), LlmCall.Media.Request.t(), Config.t()) :: :ok
  def assert_capabilities(codec, request, config) do
    assert Code.ensure_loaded?(codec), "#{inspect(codec)} is not loaded"

    assert %MediaCapabilities{async: async, modalities: modalities} =
             codec.capabilities(request, config),
           "#{inspect(codec)}.capabilities/2 must return %LlmCall.Media.Capabilities{}"

    if async do
      assert function_exported?(codec, :decode_operation, 2),
             "#{inspect(codec)} declares async: true but does not export decode_operation/2"
    else
      refute function_exported?(codec, :decode_operation, 2),
             "#{inspect(codec)} declares async: false but exports decode_operation/2"
    end

    assert request.modality in modalities,
           "#{inspect(codec)} does not declare modality #{inspect(request.modality)}"

    :ok
  end

  @spec assert_submit_path(module(), LlmCall.Media.Request.t(), String.t()) :: :ok
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

  @doc """
  Checks one `LlmCall.Operation` against the state-machine invariants.

  A state a codec can return must satisfy: `:queued`/`:in_progress` poll with no
  result; `:completed` never polls, always has a result, and an `:asset` fetch
  names its media type; `:failed` carries an error and nothing else.
  """
  @spec assert_operation(Operation.t()) :: :ok
  def assert_operation(%Operation{} = operation) do
    case operation.status do
      status when status in [:queued, :in_progress] ->
        assert operation.result == nil,
               "#{inspect(status)} operation must not carry a result"

        assert operation.next_kind == :poll,
               "#{inspect(status)} operation must poll, got next_kind: #{inspect(operation.next_kind)}"

        assert operation.error == nil,
               "#{inspect(status)} operation must not carry an error"

        assert match?(%EncodedRequest{}, operation.next),
               "#{inspect(status)} operation must carry the next request"

      :completed ->
        refute operation.next_kind == :poll,
               "a completed operation must not poll; it either carries assets or an :asset fetch"

        assert match?(%MediaResponse{}, operation.result),
               "a completed operation must carry a media response result"

        assert operation.error == nil, "a completed operation must not carry an error"

        case operation.next_kind do
          :asset ->
            assert match?(%EncodedRequest{}, operation.next),
                   "an :asset fetch must carry the next request"

            assert is_binary(operation.next_media_type),
                   "an :asset fetch must name its media type"

          nil ->
            assert match?([_ | _], operation.result.assets),
                   "a completed operation with no next request must carry at least one asset"

          other ->
            flunk("unexpected next_kind on a completed operation: #{inspect(other)}")
        end

      :failed ->
        assert operation.next == nil, "a failed operation must not carry a next request"
        assert operation.result == nil, "a failed operation must not carry a result"
        assert match?(%Error{}, operation.error), "a failed operation must carry an error"

      other ->
        flunk("unexpected operation status: #{inspect(other)}")
    end

    :ok
  end

  @doc """
  Checks that `capabilities/2` and `validate_request/2` agree.

  Every declared `size`, `aspect_ratio`, `duration_s`, and `max_n` must be
  accepted, and an undeclared non-nil value must be a validation error.
  """
  @spec assert_capability_consistency(module(), MediaRequest.t(), Config.t()) :: :ok
  def assert_capability_consistency(codec, base_request, config) do
    capabilities = codec.capabilities(base_request, config)

    check_declared(codec, base_request, config, capabilities.sizes, :size, "3x3")
    check_declared(codec, base_request, config, capabilities.aspect_ratios, :aspect_ratio, "0:0")
    check_declared(codec, base_request, config, capabilities.durations_s, :duration_s, 10_000)
    check_max_n(codec, base_request, config, capabilities.max_n)
    check_flag(codec, base_request, config, :seed, capabilities.seed, 1)

    check_flag(
      codec,
      base_request,
      config,
      :negative_prompt,
      capabilities.negative_prompt,
      "ugly"
    )

    check_max_references(codec, base_request, config, capabilities.max_references)

    :ok
  end

  defp check_declared(_codec, _request, _config, [], _key, _sentinel), do: :ok

  defp check_declared(codec, request, config, values, key, sentinel) do
    Enum.each(values, fn value ->
      assert :ok == codec.validate_request(with_param(request, key, value), config),
             "#{inspect(codec)} declares #{key} #{inspect(value)} but rejects it"
    end)

    unless sentinel in values do
      result = codec.validate_request(with_param(request, key, sentinel), config)

      assert match?({:error, %Error{kind: :validation}}, result),
             "#{inspect(codec)} accepts an undeclared #{key} #{inspect(sentinel)}: #{inspect(result)}"
    end

    :ok
  end

  defp check_max_n(codec, request, config, :unsupported) do
    result = codec.validate_request(with_param(request, :n, 1), config)

    assert match?({:error, %Error{kind: :validation}}, result),
           "#{inspect(codec)} declares max_n: :unsupported but accepts n: 1"

    :ok
  end

  defp check_max_n(codec, request, config, max_n) do
    assert :ok == codec.validate_request(with_param(request, :n, max_n), config),
           "#{inspect(codec)} declares max_n #{max_n} but rejects n: #{max_n}"

    result = codec.validate_request(with_param(request, :n, max_n + 1), config)

    assert match?({:error, %Error{kind: :validation}}, result),
           "#{inspect(codec)} accepts n: #{max_n + 1} beyond max_n #{max_n}"

    :ok
  end

  defp check_flag(codec, request, config, key, true, value) do
    assert :ok == codec.validate_request(with_param(request, key, value), config),
           "#{inspect(codec)} declares #{key}: true but rejects #{key}: #{inspect(value)}"

    :ok
  end

  defp check_flag(codec, request, config, key, false, value) do
    result = codec.validate_request(with_param(request, key, value), config)

    assert match?({:error, %Error{kind: :validation}}, result),
           "#{inspect(codec)} declares #{key}: false but accepts #{key}: #{inspect(value)}"

    :ok
  end

  defp check_max_references(codec, request, config, nil) do
    result = codec.validate_request(%{request | references: references(1)}, config)

    assert match?({:error, %Error{kind: :validation}}, result),
           "#{inspect(codec)} declares max_references: nil but accepts a reference"

    :ok
  end

  defp check_max_references(codec, request, config, max) do
    assert :ok == codec.validate_request(%{request | references: references(max)}, config),
           "#{inspect(codec)} declares max_references: #{max} but rejects #{max} references"

    result = codec.validate_request(%{request | references: references(max + 1)}, config)

    assert match?({:error, %Error{kind: :validation}}, result),
           "#{inspect(codec)} accepts #{max + 1} references beyond max_references: #{max}"

    :ok
  end

  defp references(count) do
    for _ <- 1..count, do: %Content.Image{source: {:url, "https://example.com/ref.png"}}
  end

  defp with_param(%MediaRequest{} = request, key, value) do
    %{request | params: Map.put(request.params, key, value)}
  end
end
