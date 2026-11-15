defmodule LlmCall.Media.Protocol.MiniMaxVideoTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Content, Error}
  alias LlmCall.Media.Fixtures.MiniMaxVideo, as: Fx
  alias LlmCall.Media.Protocol.MiniMax.Video
  alias LlmCall.Media.Request, as: MediaRequest
  alias LlmCall.Media.Response, as: MediaResponse
  alias LlmCall.Operation

  defp request(overrides \\ []) do
    struct(
      %MediaRequest{modality: :video, model: "MiniMax-Hailuo-2.3", prompt: "a cat surfing"},
      overrides
    )
  end

  test "info and capabilities" do
    assert %LlmCall.Codec.Info{
             name: :minimax_video,
             protocol: :minimax_video,
             version: "v1",
             ir_version: 1
           } =
             Video.info()

    assert %LlmCall.Media.Capabilities{
             modalities: [:video],
             async: true,
             max_n: :unsupported,
             sizes: [],
             aspect_ratios: [],
             durations_s: [6, 10],
             max_references: 1,
             seed: false,
             negative_prompt: false
           } = Video.capabilities(request(), %Config{})
  end

  test "encodes prompt, duration and the first-frame reference" do
    assert {:ok, encoded} = Video.encode_submit(request(), %Config{})
    assert encoded.method == :post
    assert encoded.path == "/v1/video_generation"
    assert encoded.query == %{}
    assert encoded.headers == [{"content-type", "application/json"}]

    assert encoded.body == %{"model" => "MiniMax-Hailuo-2.3", "prompt" => "a cat surfing"}

    assert encode_body(request(params: %{duration_s: 10}))["duration"] == 10

    body =
      encode_body(
        request(references: [%Content.Image{source: {:url, "https://example.com/f.png"}}])
      )

    assert body["first_frame_image"] == "https://example.com/f.png"

    body =
      encode_body(
        request(references: [%Content.Image{source: {:base64, "AAA"}, media_type: "image/png"}])
      )

    assert body["first_frame_image"] == "data:image/png;base64,AAA"
  end

  test "native knobs go through provider_options" do
    body =
      encode_body(
        request(
          provider_options: %{minimax: %{"resolution" => "1080P", "prompt_optimizer" => false}}
        )
      )

    assert body["resolution"] == "1080P"
    assert body["prompt_optimizer"] == false
  end

  test "unsupported knobs and references are validation errors" do
    for request <- [
          request(modality: :image),
          request(params: %{size: "1280x720"}),
          request(params: %{aspect_ratio: "16:9"}),
          request(params: %{seed: 1}),
          request(params: %{negative_prompt: "x"}),
          request(params: %{duration_s: 8}),
          request(references: [%Content.Video{source: {:url, "u"}}]),
          request(references: List.duplicate(%Content.Image{source: {:url, "u"}}, 2)),
          request(references: [%Content.Image{source: {:base64, "AAA"}}]),
          request(provider_options: %{minimax: %{"prompt" => "x"}}),
          %MediaRequest{modality: :video, model: "MiniMax-Hailuo-2.3"},
          %MediaRequest{modality: :video, prompt: "x"}
        ] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Video.validate_request(request, %Config{})

      assert is_binary(message)
      assert {:error, %Error{kind: :validation}} = Video.encode_submit(request, %Config{})
    end
  end

  test "a submit response becomes a queued operation polling the task" do
    assert {:ok, %MediaResponse{assets: [], operation: operation}} =
             Video.decode_submit(Fx.submit_response(), %Config{})

    assert %Operation{
             id: "task_123",
             status: :queued,
             next_kind: :poll,
             next: %{
               method: :get,
               path: "/v1/query/video_generation",
               query: %{"task_id" => "task_123"}
             }
           } = operation

    assert :ok = LlmCall.MediaConformance.assert_operation(operation)
  end

  test "queueing and processing stay in progress on the query endpoint" do
    for {payload, status} <- [
          {Fx.preparing_response(), :in_progress},
          {Fx.queueing_response(), :in_progress},
          {Fx.processing_response(), :in_progress}
        ] do
      assert {:ok,
              %Operation{
                status: ^status,
                next_kind: :poll,
                next: %{path: "/v1/query/video_generation"}
              } = operation} = Video.decode_operation(payload, %Config{})

      assert :ok = LlmCall.MediaConformance.assert_operation(operation)
    end
  end

  test "Success carries only a file_id, so the job moves to the file retrieve step" do
    assert {:ok,
            %Operation{
              status: :in_progress,
              next_kind: :poll,
              next: %{
                method: :get,
                path: "/v1/files/retrieve",
                query: %{"file_id" => "987654"}
              }
            } = operation} = Video.decode_operation(Fx.success_response(), %Config{})

    assert :ok = LlmCall.MediaConformance.assert_operation(operation)
  end

  test "the file retrieve payload completes the job with a download url" do
    assert {:ok,
            %Operation{
              id: nil,
              status: :completed,
              next: nil,
              result: %MediaResponse{
                assets: [
                  %Content.Video{
                    source: {:url, "https://files.example/v.mp4"},
                    media_type: "video/mp4"
                  }
                ]
              }
            } = done} = Video.decode_operation(Fx.retrieve_response(), %Config{})

    assert :ok = LlmCall.MediaConformance.assert_operation(done)
  end

  test "Fail and a non-zero base_resp are provider errors" do
    assert {:ok,
            %Operation{
              status: :failed,
              next: nil,
              result: nil,
              error: %Error{kind: :provider}
            } = failed} = Video.decode_operation(Fx.fail_response(), %Config{})

    assert :ok = LlmCall.MediaConformance.assert_operation(failed)

    for payload <- [
          Fx.submit_error_response(),
          Fx.query_error_response(),
          Fx.retrieve_error_response()
        ] do
      result =
        if Map.has_key?(payload, "task_id") do
          Video.decode_submit(payload, %Config{})
        else
          Video.decode_operation(payload, %Config{})
        end

      assert {:error, %Error{kind: :provider, message: message}} = result

      assert is_binary(message)
    end
  end

  test "a status payload without a task id is an invalid response" do
    assert {:error, %Error{kind: :invalid_response}} =
             Video.decode_operation(%{"status" => "Processing"}, %Config{})
  end

  test "a non-map error value does not crash the failed-operation decoder" do
    payload = %{"task_id" => "task_123", "status" => "Fail", "error" => "boom"}

    assert {:ok, %Operation{status: :failed, error: %Error{kind: :provider}}} =
             Video.decode_operation(payload, %Config{})
  end

  test "base_resp errors surface from the decoder a caller actually uses" do
    assert {:error, %Error{kind: :provider, message: "Timeout"}} =
             Video.decode_operation(Fx.query_error_response(), %Config{})

    assert {:error, %Error{kind: :provider, message: "Insufficient balance"}} =
             Video.decode_submit(Fx.submit_error_response(), %Config{})
  end

  test "n is rejected although max_n is nil" do
    assert {:error, %Error{kind: :validation}} =
             Video.validate_request(request(params: %{n: 1}), %Config{})
  end

  test "Success without a file_id and unknown payloads are invalid responses" do
    assert {:error, %Error{kind: :invalid_response}} =
             Video.decode_operation(Fx.success_without_file_response(), %Config{})

    assert {:error, %Error{kind: :invalid_response}} =
             Video.decode_operation(%{"status" => "whatever"}, %Config{})

    assert {:error, %Error{kind: :invalid_response}} =
             Video.decode_operation(%{"nope" => 1}, %Config{})
  end

  test "capture_raw applies to submit, query and retrieve payloads" do
    submit = Fx.submit_response()
    query = Fx.processing_response()
    retrieve = Fx.retrieve_response()

    assert {:ok, %MediaResponse{raw: ^submit}} =
             Video.decode_submit(submit, %Config{capture_raw: :all})

    assert {:ok, %Operation{raw: ^query}} =
             Video.decode_operation(query, %Config{capture_raw: :response})

    assert {:ok, %Operation{raw: ^retrieve}} =
             Video.decode_operation(retrieve, %Config{capture_raw: :all})

    assert {:ok, %Operation{raw: nil}} = Video.decode_operation(query, %Config{})
  end

  test "decode_error/2 turns a base_resp error into a provider error" do
    assert %Error{
             kind: :provider,
             message: "Insufficient balance",
             code: "1008",
             retryable?: false
           } = Video.decode_error(Fx.error_payload(), %Config{})

    assert %Error{kind: :provider, code: "1002", retryable?: true} =
             Video.decode_error(Fx.rate_limit_payload(), %Config{})

    assert %Error{kind: :invalid_response} = Video.decode_error("boom", %Config{})
  end

  defp encode_body(request) do
    assert {:ok, encoded} = Video.encode_submit(request, %Config{})
    encoded.body
  end
end
