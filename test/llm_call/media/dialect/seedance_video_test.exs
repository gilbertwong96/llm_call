defmodule LlmCall.Media.Dialect.SeedanceVideoTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Content, Error}
  alias LlmCall.Media.Dialect.Seedance.Video
  alias LlmCall.Media.Fixtures.SeedanceVideo, as: Fx
  alias LlmCall.Media.Request, as: MediaRequest
  alias LlmCall.Media.Response, as: MediaResponse
  alias LlmCall.Operation

  defp request(overrides \\ []) do
    struct(
      %MediaRequest{modality: :video, model: "seedance-1-5-pro-251215", prompt: "a cat surfing"},
      overrides
    )
  end

  test "info and capabilities" do
    assert %LlmCall.Codec.Info{name: :seedance_video, protocol: :seedance_video, ir_version: 1} =
             Video.info()

    assert %LlmCall.Media.Capabilities{
             modalities: [:video],
             async: true,
             max_n: :unsupported,
             sizes: [],
             aspect_ratios: ratios,
             durations_s: durations,
             max_references: 2,
             seed: true,
             negative_prompt: false
           } = Video.capabilities(request(), %Config{})

    assert "16:9" in ratios
    assert "adaptive" in ratios
    assert 5 in durations
    assert 12 in durations
  end

  test "encodes the text part, ratio, duration and seed" do
    assert {:ok, encoded} = Video.encode_submit(request(), %Config{})
    assert encoded.method == :post
    assert encoded.path == "/api/v3/contents/generations/tasks"
    assert encoded.query == %{}
    assert encoded.headers == [{"content-type", "application/json"}]

    assert encoded.body == %{
             "model" => "seedance-1-5-pro-251215",
             "content" => [%{"type" => "text", "text" => "a cat surfing"}]
           }

    body = encode_body(request(params: %{aspect_ratio: "9:16", duration_s: 10, seed: 42}))
    assert body["ratio"] == "9:16"
    assert body["duration"] == 10
    assert body["seed"] == 42
  end

  test "references become image_url content parts" do
    body =
      encode_body(
        request(
          references: [
            %Content.Image{source: {:url, "https://example.com/first.png"}},
            %Content.Image{source: {:base64, "AAA"}, media_type: "image/png"}
          ]
        )
      )

    assert body["content"] == [
             %{"type" => "text", "text" => "a cat surfing"},
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "https://example.com/first.png"},
               "role" => "first_frame"
             },
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/png;base64,AAA"},
               "role" => "last_frame"
             }
           ]
  end

  test "a single reference is the first frame" do
    body =
      encode_body(
        request(references: [%Content.Image{source: {:url, "https://example.com/first.png"}}])
      )

    assert [_, image] = body["content"]
    assert image["role"] == "first_frame"
  end

  test "no references encodes without content images" do
    for references <- [nil, []] do
      body = encode_body(request(references: references))
      assert [%{"type" => "text"}] = body["content"]
    end
  end

  test "durations below and above the declared union are rejected" do
    for duration <- [1, 31] do
      assert {:error, %Error{kind: :validation}} =
               Video.validate_request(request(params: %{duration_s: duration}), %Config{})
    end

    for duration <- [2, 30] do
      assert :ok = Video.validate_request(request(params: %{duration_s: duration}), %Config{})
    end
  end

  test "a status payload without a task id is an invalid response" do
    assert {:error, %Error{kind: :invalid_response}} =
             Video.decode_operation(%{"status" => "running"}, %Config{})
  end

  test "native knobs go through provider_options" do
    body =
      encode_body(
        request(
          provider_options: %{
            seedance: %{"resolution" => "1080p", "watermark" => false, "generate_audio" => true}
          }
        )
      )

    assert body["resolution"] == "1080p"
    assert body["watermark"] == false
    assert body["generate_audio"] == true
  end

  test "unsupported knobs and references are validation errors" do
    for request <- [
          request(modality: :image),
          request(params: %{size: "1280x720"}),
          request(params: %{n: 1}),
          request(params: %{negative_prompt: "x"}),
          request(params: %{aspect_ratio: "7:3"}),
          request(params: %{duration_s: 31}),
          request(params: %{duration_s: 1}),
          request(references: [%Content.Video{source: {:url, "u"}}]),
          request(references: [%Content.Image{source: {:base64, "AAA"}}]),
          request(references: List.duplicate(%Content.Image{source: {:url, "u"}}, 3)),
          request(provider_options: %{seedance: %{"content" => []}}),
          %MediaRequest{modality: :video, model: "seedance"},
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
             id: "cgt-2026-abc",
             status: :queued,
             next_kind: :poll,
             next: %{method: :get, path: "/api/v3/contents/generations/tasks/cgt-2026-abc"}
           } = operation

    assert :ok = LlmCall.Media.Conformance.assert_operation(operation)
  end

  test "poll paths encode the task id as one path segment" do
    assert {:ok, %Operation{next: next}} =
             Video.decode_operation(%{"id" => "foo/bar", "status" => "running"}, %Config{})

    assert next.path == "/api/v3/contents/generations/tasks/foo%2Fbar"
  end

  test "failed operations normalize numeric provider codes to strings" do
    assert {:ok, %Operation{status: :failed, error: %Error{code: "123"}}} =
             Video.decode_operation(
               %{"status" => "failed", "error" => %{"code" => 123}},
               %Config{}
             )
  end

  test "operation ids are strings even when the provider sends a number" do
    for payload <- [
          %{"status" => "queued", "id" => 1},
          %{"status" => "running", "id" => 1},
          %{"status" => "failed", "id" => 1, "error" => %{"message" => "m"}},
          %{"status" => "succeeded", "id" => 1, "content" => %{"video_url" => "u"}}
        ] do
      assert {:ok, %Operation{} = operation} = Video.decode_operation(payload, %Config{})
      assert operation.id == "1"
    end
  end

  test "operation raw follows the capture_raw policy" do
    assert :ok =
             LlmCall.Media.Conformance.assert_operation_capture_raw(
               Video,
               Fx.succeeded_response(),
               %Config{}
             )
  end

  test "polling maps queued, running, succeeded and terminal failures" do
    for {payload, status} <- [
          {Fx.queued_response(), :queued},
          {Fx.running_response(), :in_progress}
        ] do
      assert {:ok, %Operation{status: ^status, next_kind: :poll} = operation} =
               Video.decode_operation(payload, %Config{})

      assert :ok = LlmCall.Media.Conformance.assert_operation(operation)
    end

    assert {:ok,
            %Operation{
              status: :completed,
              next: nil,
              result: %MediaResponse{
                usage: %LlmCall.Usage{output_tokens: 24_684, total_tokens: 24_684},
                assets: [
                  %Content.Video{
                    source: {:url, "https://files.example/v.mp4"},
                    media_type: "video/mp4"
                  }
                ]
              }
            } = done} = Video.decode_operation(Fx.succeeded_response(), %Config{})

    assert :ok = LlmCall.Media.Conformance.assert_operation(done)

    for payload <- [Fx.failed_response(), Fx.cancelled_response(), Fx.expired_response()] do
      assert {:ok,
              %Operation{status: :failed, next: nil, result: nil, error: %Error{kind: :provider}} =
                failed} = Video.decode_operation(payload, %Config{})

      assert :ok = LlmCall.Media.Conformance.assert_operation(failed)
    end
  end

  test "a succeeded task without a video url is an invalid response" do
    assert {:error, %Error{kind: :invalid_response}} =
             Video.decode_operation(Fx.succeeded_without_url_response(), %Config{})

    assert {:error, %Error{kind: :invalid_response}} =
             Video.decode_operation(%{"id" => "cgt-1", "status" => "weird"}, %Config{})

    assert {:error, %Error{kind: :invalid_response}} =
             Video.decode_operation(%{"nope" => 1}, %Config{})
  end

  test "capture_raw applies to submit and poll payloads" do
    submit = Fx.submit_response()
    poll = Fx.running_response()

    assert {:ok, %MediaResponse{raw: ^submit}} =
             Video.decode_submit(submit, %Config{capture_raw: :all})

    assert {:ok, %Operation{raw: ^poll}} =
             Video.decode_operation(poll, %Config{capture_raw: :response})

    assert {:ok, %Operation{raw: nil}} = Video.decode_operation(poll, %Config{})
  end

  test "decode_error/2 normalizes the ModelArk envelope" do
    assert %Error{
             kind: :provider,
             message: "Invalid parameter",
             code: "InvalidParameter",
             retryable?: false
           } = Video.decode_error(Fx.error_payload(), %Config{})

    assert %Error{kind: :invalid_response} = Video.decode_error("boom", %Config{})
  end

  defp encode_body(request) do
    assert {:ok, encoded} = Video.encode_submit(request, %Config{})
    encoded.body
  end
end
