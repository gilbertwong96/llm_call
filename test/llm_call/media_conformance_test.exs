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
