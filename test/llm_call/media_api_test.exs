defmodule LlmCall.MediaApiTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Content, Error, Operation}
  alias LlmCall.Media.Request, as: MediaRequest
  alias LlmCall.Media.Response, as: MediaResponse
  alias LlmCall.TestCodec.{AsyncMedia, FakeMedia}

  defp request(overrides \\ []) do
    struct(%MediaRequest{modality: :image, model: "fake-1", prompt: "a cat"}, overrides)
  end

  test "encode_media/3 delegates and validates first" do
    assert {:ok, encoded} = LlmCall.encode_media(FakeMedia, request())
    assert encoded.path == "/fake/images"
    assert encoded.body == %{"prompt" => "a cat"}

    assert {:error, %Error{kind: :validation}} =
             LlmCall.encode_media(FakeMedia, %MediaRequest{})
  end

  test "validate_media/3 and media_capabilities/3 delegate" do
    assert :ok = LlmCall.validate_media(FakeMedia, request())

    assert {:ok,
            %LlmCall.Media.Capabilities{modalities: [:image], max_n: 4, sizes: ["1024x1024"]}} =
             LlmCall.media_capabilities(FakeMedia, request())
  end

  test "media dispatch rejects a completion codec instead of raising" do
    for fun <- [:encode_media, :decode_media, :validate_media, :media_capabilities] do
      assert {:error, %Error{kind: :validation, message: message}} =
               apply(LlmCall, fun, [LlmCall.TestCodec.Fake, request()])

      assert message =~ "does not support"
    end
  end

  test "decode_media/3 decodes assets and honors capture_raw" do
    payload = %{"images" => ["AAA"], "revised_prompt" => "a fluffy cat"}

    assert {:ok,
            %MediaResponse{
              assets: [%Content.Image{source: {:base64, "AAA"}}],
              revised_prompt: "a fluffy cat",
              raw: nil
            }} = LlmCall.decode_media(FakeMedia, payload)

    assert {:ok, %MediaResponse{raw: ^payload}} =
             LlmCall.decode_media(FakeMedia, payload, %Config{capture_raw: :response})

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.decode_media(FakeMedia, %{"nope" => 1})
  end

  test "a synchronous codec returns a typed error for decode_operation/3" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.decode_operation(FakeMedia, %{"status" => "completed"})

    assert message =~ "does not support"
    assert message =~ "decode_operation/2"
  end

  test "an async submit carries the next poll request" do
    assert {:ok,
            %MediaResponse{
              operation:
                %Operation{
                  id: "job_1",
                  status: :queued,
                  next: %{method: :get, path: "/fake/jobs/1"},
                  next_kind: :poll
                } = operation
            }} = LlmCall.decode_media(AsyncMedia, %{"id" => "job_1"})

    assert operation.result == nil
  end

  test "an in-progress poll keeps polling and does not carry a result" do
    assert {:ok,
            %Operation{
              status: :in_progress,
              progress: 40,
              result: nil,
              next_kind: :poll,
              next: %{method: :get}
            }} = LlmCall.decode_operation(AsyncMedia, %{"status" => "in_progress"})
  end

  test "a completed job carries assets and no next request" do
    assert {:ok,
            %Operation{
              status: :completed,
              next: nil,
              result: %MediaResponse{
                assets: [%Content.Video{source: {:url, "https://x/v.mp4"}}]
              }
            }} =
             LlmCall.decode_operation(AsyncMedia, %{
               "status" => "completed",
               "url" => "https://x/v.mp4"
             })
  end

  test "a completed job whose bytes need a fetch returns next_kind: :asset" do
    assert {:ok,
            %Operation{
              status: :completed,
              next_kind: :asset,
              next_media_type: "video/mp4",
              next: %{method: :get, path: "/fake/jobs/1/content"},
              result: %MediaResponse{assets: []}
            }} =
             LlmCall.decode_operation(AsyncMedia, %{
               "status" => "completed",
               "asset_path" => "/fake/jobs/1/content"
             })
  end

  test "a failed job carries an error and no next request" do
    assert {:ok,
            %Operation{
              status: :failed,
              next: nil,
              result: nil,
              error: %Error{kind: :provider, message: "boom"}
            }} =
             LlmCall.decode_operation(AsyncMedia, %{"status" => "failed", "message" => "boom"})
  end

  test "operation raw payloads honor capture_raw" do
    payload = %{"status" => "in_progress"}

    assert {:ok, %Operation{raw: nil}} = LlmCall.decode_operation(AsyncMedia, payload)

    assert {:ok, %Operation{raw: ^payload}} =
             LlmCall.decode_operation(AsyncMedia, payload, %Config{capture_raw: :all})
  end

  test "encode_media/3 surfaces media validation errors from the codec" do
    assert {:error, %Error{kind: :validation}} =
             LlmCall.encode_media(FakeMedia, request(modality: :video))
  end
end
