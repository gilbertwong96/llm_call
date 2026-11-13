defmodule LlmCall.TestCodec.SloppyMaxN do
  @moduledoc "Declares `max_n: 1` but accepts any `n`, so conformance must catch it."

  @behaviour LlmCall.Media.Codec

  alias LlmCall.{Codec, Config, Error, Media.Capabilities, Media.Request}

  @impl true
  def info, do: %Codec.Info{name: :sloppy_max_n, protocol: :sloppy_max_n, ir_version: 1}

  @impl true
  def capabilities(_request, _config),
    do: %Capabilities{modalities: [:video], async: true, max_n: 1}

  @impl true
  def validate_request(%Request{}, %Config{}), do: :ok

  @impl true
  def encode_submit(_request, _config), do: {:ok, %LlmCall.EncodedRequest{path: "/sloppy"}}

  @impl true
  def decode_submit(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "sloppy_max_n"}}

  @impl true
  def decode_operation(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "sloppy_max_n"}}

  @impl true
  def decode_error(_term, _config), do: %Error{kind: :provider, message: "sloppy_max_n"}
end

defmodule LlmCall.TestCodec.SloppyRefs do
  @moduledoc "Declares `max_references: 1` but accepts any references, so conformance must catch it."

  @behaviour LlmCall.Media.Codec

  alias LlmCall.{Codec, Config, Error, Media.Capabilities, Media.Request}

  @impl true
  def info, do: %Codec.Info{name: :sloppy_refs, protocol: :sloppy_refs, ir_version: 1}

  @impl true
  def capabilities(_request, _config),
    do: %Capabilities{modalities: [:video], async: true, max_references: 1}

  @impl true
  def validate_request(%Request{params: params}, %Config{}) do
    cond do
      Map.has_key?(params, :n) ->
        {:error, %Error{kind: :validation, message: "sloppy_refs: n"}}

      Map.has_key?(params, :seed) ->
        {:error, %Error{kind: :validation, message: "sloppy_refs: seed"}}

      Map.has_key?(params, :negative_prompt) ->
        {:error, %Error{kind: :validation, message: "sloppy_refs: neg"}}

      true ->
        :ok
    end
  end

  @impl true
  def encode_submit(_request, _config), do: {:ok, %LlmCall.EncodedRequest{path: "/sloppy"}}

  @impl true
  def decode_submit(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "sloppy_refs"}}

  @impl true
  def decode_operation(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "sloppy_refs"}}

  @impl true
  def decode_error(_term, _config), do: %Error{kind: :provider, message: "sloppy_refs"}
end

defmodule LlmCall.MediaConformanceTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Operation}
  alias LlmCall.Media.Request, as: MediaRequest
  alias LlmCall.Media.Response, as: MediaResponse
  alias LlmCall.MediaConformance

  defp request(model) do
    %MediaRequest{modality: :image, model: model, prompt: "a cat"}
  end

  test "conformance assertions catch a violating codec" do
    codec = LlmCall.TestCodec.FakeMedia

    assert_raise ExUnit.AssertionError, fn ->
      MediaConformance.assert_submit_path(codec, request("fake-1"), "/wrong")
    end

    assert_raise ExUnit.AssertionError, fn ->
      MediaConformance.assert_capture_raw(codec, %{"nope" => 1})
    end

    assert :ok = MediaConformance.assert_sync_rejects_operation(codec)
  end

  test "an async declaration without decode_operation/2 is caught" do
    assert_raise ExUnit.AssertionError, ~r/decode_operation/, fn ->
      MediaConformance.assert_capabilities(
        LlmCall.TestCodec.BrokenAsyncMedia,
        request("fake-1"),
        %Config{}
      )
    end
  end

  test "assert_operation/1 accepts every legal state" do
    poll = %LlmCall.EncodedRequest{method: :get, path: "/jobs/1"}

    for operation <- [
          %Operation{status: :queued, next: poll, next_kind: :poll},
          %Operation{status: :in_progress, progress: 40, next: poll, next_kind: :poll},
          %Operation{
            status: :completed,
            result: %MediaResponse{assets: []},
            next: poll,
            next_kind: :asset,
            next_media_type: "video/mp4"
          },
          %Operation{
            status: :completed,
            result: %MediaResponse{assets: [%LlmCall.Content.Video{source: {:url, "u"}}]}
          },
          %Operation{status: :failed, error: %LlmCall.Error{kind: :provider, message: "boom"}}
        ] do
      assert :ok = MediaConformance.assert_operation(operation)
    end
  end

  test "assert_operation/1 rejects illegal states" do
    poll = %LlmCall.EncodedRequest{method: :get, path: "/jobs/1"}

    for operation <- [
          %Operation{status: :completed, next: poll, next_kind: :poll, result: %MediaResponse{}},
          %Operation{status: :completed, next: poll, next_kind: :asset, result: %MediaResponse{}},
          %Operation{status: :completed, next_kind: :asset, next_media_type: "video/mp4"},
          %Operation{status: :in_progress},
          %Operation{status: :failed, next: poll},
          %Operation{
            status: :failed,
            error: %LlmCall.Error{kind: :provider, message: "x"},
            result: %MediaResponse{}
          }
        ] do
      assert_raise ExUnit.AssertionError, fn -> MediaConformance.assert_operation(operation) end
    end
  end

  test "assert_capability_consistency/3 catches a declared n or reference cap" do
    request = %MediaRequest{modality: :video, model: "sloppy", prompt: "a cat"}

    assert_raise ExUnit.AssertionError, ~r/max_n/, fn ->
      MediaConformance.assert_capability_consistency(
        LlmCall.TestCodec.SloppyMaxN,
        request,
        %Config{}
      )
    end

    assert_raise ExUnit.AssertionError, ~r/max_references/, fn ->
      MediaConformance.assert_capability_consistency(
        LlmCall.TestCodec.SloppyRefs,
        request,
        %Config{}
      )
    end
  end

  test "assert_capability_consistency/3 requires a declared flag to be accepted" do
    assert_raise ExUnit.AssertionError, ~r/seed/, fn ->
      MediaConformance.assert_capability_consistency(
        LlmCall.TestCodec.FlagMedia,
        %MediaRequest{modality: :image, model: "flag-1", prompt: "a cat"},
        %Config{}
      )
    end
  end

  test "an in-core fake keeps a passing conformance path" do
    request = %MediaRequest{modality: :video, model: "async-1", prompt: "a cat"}

    assert :ok =
             MediaConformance.assert_capability_consistency(
               LlmCall.TestCodec.AsyncMedia,
               request,
               %Config{}
             )
  end

  test "assert_capability_consistency/3 catches a declaration validation does not honour" do
    assert_raise ExUnit.AssertionError, fn ->
      MediaConformance.assert_capability_consistency(
        LlmCall.TestCodec.FakeMedia,
        %MediaRequest{modality: :image, model: "fake-1", prompt: "a cat"},
        %Config{}
      )
    end
  end
end
