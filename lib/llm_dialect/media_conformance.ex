defmodule LlmDialect.MediaConformance do
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

  alias LlmDialect.{Config, Content, EncodedRequest, Error, Operation}
  alias LlmDialect.Media.Capabilities, as: MediaCapabilities
  alias LlmDialect.Media.Request, as: MediaRequest
  alias LlmDialect.Media.Response, as: MediaResponse

  @doc "Asserts well-formed `info/0` metadata (see `LlmDialect.Conformance`)."
  @spec assert_info(module()) :: :ok
  def assert_info(codec), do: LlmDialect.Conformance.assert_info(codec)

  @spec assert_capabilities(module(), LlmDialect.Media.Request.t(), Config.t()) :: :ok
  def assert_capabilities(codec, request, config) do
    assert Code.ensure_loaded?(codec), "#{inspect(codec)} is not loaded"

    assert %MediaCapabilities{async: async, modalities: modalities} =
             codec.capabilities(request, config),
           "#{inspect(codec)}.capabilities/2 must return %LlmDialect.Media.Capabilities{}"

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

  @spec assert_submit_path(module(), LlmDialect.Media.Request.t(), String.t()) :: :ok
  def assert_submit_path(codec, request, expected_path) do
    result = codec.encode_submit(request, %Config{})

    assert match?({:ok, %EncodedRequest{}}, result),
           "#{inspect(codec)}.encode_submit/2 must return {:ok, %LlmDialect.EncodedRequest{}}, " <>
             "got: #{inspect(result)}"

    {:ok, %EncodedRequest{} = encoded} = result

    assert encoded.method == :post
    assert encoded.path == expected_path

    assert_encoded_request(encoded, inspect(codec))

    :ok
  end

  @doc """
  Asserts the shape of any encoded request: a map body, a map query, a list of
  headers, and no credential header.

  `assert_operation/1` runs this over `Operation.next`, so a poll or asset-fetch
  request cannot smuggle an `authorization` header past the submit check.
  """
  @spec assert_encoded_request(EncodedRequest.t(), String.t()) :: :ok
  def assert_encoded_request(%EncodedRequest{} = encoded, label) do
    assert is_map(encoded.body), "#{label} encoded body must be a map"
    assert is_map(encoded.query), "#{label} encoded query must be a map"
    assert is_list(encoded.headers), "#{label} encoded headers must be a list"

    names = Enum.map(encoded.headers, fn {name, _value} -> String.downcase(name) end)

    for forbidden <- LlmDialect.Conformance.credential_headers() do
      refute forbidden in names,
             "#{label} encoded request contains a credential header #{inspect(forbidden)}"
    end

    :ok
  end

  @spec assert_capture_raw(module(), LlmDialect.wire_value()) :: :ok
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
             LlmDialect.decode_operation(codec, %{}, %Config{}),
           "#{inspect(codec)} is synchronous, so decode_operation/3 must be a validation error"

    :ok
  end

  @doc """
  Asserts that `decode_operation/2` applies the `capture_raw` policy to
  `Operation.raw`.

  The operation payload is the provider's job body, so `:none` must drop it and
  `:response`/`:all` must keep it, matching `decode_submit/2`. `Error.raw` is
  intentionally unconditional: an error keeps the payload it came from.
  """
  @spec assert_operation_capture_raw(module(), LlmDialect.wire_value(), Config.t()) :: :ok
  def assert_operation_capture_raw(codec, provider_payload, base_config \\ %Config{}) do
    for {capture, expected} <- [none: nil, response: provider_payload, all: provider_payload] do
      config = %{base_config | capture_raw: capture}

      case codec.decode_operation(provider_payload, config) do
        {:ok, %Operation{raw: raw}} ->
          assert raw == expected,
                 "#{inspect(codec)} Operation.raw must be #{inspect(expected)} with " <>
                   "capture_raw: #{inspect(capture)}, got: #{inspect(raw)}"

        other ->
          flunk(
            "#{inspect(codec)}.decode_operation/2 must succeed with " <>
              "capture_raw: #{inspect(capture)}, got: #{inspect(other)}"
          )
      end
    end

    :ok
  end

  defp assert_operation_raw(%Operation{raw: raw}) do
    assert is_nil(raw) or is_map(raw),
           "Operation.raw must be a map or nil, got: #{inspect(raw)}"

    :ok
  end

  @doc """
  Checks one `LlmDialect.Operation` against the state-machine invariants.

  A state a codec can return must satisfy: `:queued`/`:in_progress` poll with no
  result; `:completed` never polls, always has a result, and an `:asset` fetch
  names its media type; `:failed` carries an error and nothing else.
  """
  @spec assert_operation(Operation.t()) :: :ok
  def assert_operation(%Operation{} = operation) do
    assert_operation_raw(operation)

    if match?(%EncodedRequest{}, operation.next) do
      assert_encoded_request(operation.next, "Operation.next")
    end

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

            assert operation.result.assets == [],
                   "a completed operation that still needs an :asset fetch must not carry assets"

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
  accepted, and an undeclared non-nil value must be a validation error. The same
  holds for the `seed` and `negative_prompt` flags and for `max_references`.
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

  defp check_max_n(codec, request, config, max_n) when is_integer(max_n) and max_n > 0 do
    for n <- 1..max_n do
      assert :ok == codec.validate_request(with_param(request, :n, n), config),
             "#{inspect(codec)} declares max_n #{max_n} but rejects n: #{n}"
    end

    result = codec.validate_request(with_param(request, :n, max_n + 1), config)

    assert match?({:error, %Error{kind: :validation}}, result),
           "#{inspect(codec)} accepts n: #{max_n + 1} beyond max_n #{max_n}"

    :ok
  end

  defp check_max_n(_codec, _request, _config, other) do
    flunk(
      "Media.Capabilities.max_n must be a positive integer or :unsupported, got: #{inspect(other)}"
    )
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

  defp check_flag(_codec, _request, _config, key, other, _value) do
    flunk("Media.Capabilities.#{key} must be a boolean, got: #{inspect(other)}")
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

  defp references(count), do: List.duplicate(reference(), count)

  defp reference, do: %Content.Image{source: {:url, "https://example.com/ref.png"}}

  defp with_param(%MediaRequest{} = request, key, value) do
    %{request | params: Map.put(request.params, key, value)}
  end
end
