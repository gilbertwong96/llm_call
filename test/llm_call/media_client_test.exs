defmodule LlmCall.MediaClientTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Error, Media, Operation}
  alias LlmCall.HTTP.Test, as: FakeHTTP
  alias LlmCall.TestMediaProvider

  setup do
    FakeHTTP.reset()
    :ok
  end

  defp client, do: TestMediaProvider.client(http: FakeHTTP)

  defp request(overrides \\ []) do
    struct(%Media.Request{modality: :image, model: "fake-1", prompt: "a cat"}, overrides)
  end

  test "generate/3 submits, decodes assets and posts to the codec path" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"images":["AAA"]})}})

    assert {:ok, %Media.Response{assets: [%LlmCall.Content.Image{source: {:base64, "AAA"}}]}} =
             LlmCall.generate(client(), request(), codec: :images)

    assert [sent] = FakeHTTP.requests()
    assert sent.url == "https://media.example.test/fake/images"
    assert {:ok, %{"prompt" => "a cat"}} = LlmCall.JSON.decode(sent.body)
  end

  test "generate/3 requires a codec name" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.generate(client(), request())

    assert message =~ "requires codec:"
    assert FakeHTTP.requests() == []
  end

  test "generate/3 returns the queued operation and poll/3 advances it" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}"}})

    assert {:ok,
            %Media.Response{operation: %Operation{status: :queued, next_kind: :poll} = queued}} =
             LlmCall.generate(client(), request(modality: :video), codec: :async)

    FakeHTTP.put_response(
      {:ok, %{status: 200, headers: [], body: ~s({"status":"completed","url":"https://x/v.mp4"})}}
    )

    assert {:ok, %Operation{status: :completed, result: %Media.Response{assets: [asset]}}} =
             LlmCall.poll(client(), queued, codec: :async)

    assert %LlmCall.Content.Video{source: {:url, "https://x/v.mp4"}} = asset
    assert List.last(FakeHTTP.requests()).url == "https://media.example.test/fake/jobs/1"
  end

  test "poll/3 sends the operation's own method, not always POST" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"status":"in_progress"})}})

    operation = %Operation{
      status: :in_progress,
      next: %LlmCall.EncodedRequest{method: :get, path: "/jobs/1"},
      next_kind: :poll
    }

    assert {:ok, %Operation{status: :in_progress}} =
             LlmCall.poll(client(), operation, codec: :async)

    assert [sent] = FakeHTTP.requests()
    assert sent.method == :get
    assert sent.body == nil
  end

  test "fetch/2 sends a GET for an asset request and returns bytes" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: <<1, 2>>}})

    encoded = %LlmCall.EncodedRequest{method: :get, path: "/assets/1"}

    assert {:ok, %{status: 200, body: <<1, 2>>}} = LlmCall.fetch(client(), encoded)

    assert [sent] = FakeHTTP.requests()
    assert sent.method == :get
    assert sent.body == nil
  end

  test "poll/3 accepts an encoded request directly" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"status":"in_progress"})}})

    encoded = %LlmCall.EncodedRequest{method: :get, path: "/jobs/9"}

    assert {:ok, %Operation{status: :in_progress}} =
             LlmCall.poll(client(), encoded, codec: :async)
  end

  test "poll/3 rejects an :asset operation and points at fetch/2" do
    operation = %Operation{
      status: :completed,
      next: %LlmCall.EncodedRequest{method: :get, path: "/asset"},
      next_kind: :asset,
      next_media_type: "video/mp4"
    }

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.poll(client(), operation, codec: :async)

    assert message =~ "fetch/2"
    assert FakeHTTP.requests() == []
  end

  test "poll/3 rejects an operation without a next request" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.poll(client(), %Operation{status: :completed}, codec: :async)

    assert message =~ "no next request"
  end

  test "a provider error envelope is decoded and carries the status" do
    FakeHTTP.put_response(
      {:ok, %{status: 429, headers: [], body: ~s({"error":{"message":"slow down"}})}}
    )

    assert {:error, %Error{kind: :provider, message: "slow down", status: 429}} =
             LlmCall.generate(client(), request(), codec: :images)
  end

  test "fetch/2 accepts an :asset operation and fetches its next request" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: <<9>>}})

    encoded = %LlmCall.EncodedRequest{method: :get, path: "/asset"}

    operation = %LlmCall.Operation{
      status: :completed,
      next: encoded,
      next_kind: :asset,
      next_media_type: "video/mp4"
    }

    assert {:ok, %{body: <<9>>}} = LlmCall.fetch(client(), operation)
    assert [%{method: :get, url: "https://media.example.test/asset"}] = FakeHTTP.requests()
  end

  test "fetch/2 returns asset bytes without decoding" do
    FakeHTTP.put_response({:ok, %{status: 200, headers: [], body: <<1, 2, 3>>}})

    encoded = %LlmCall.EncodedRequest{method: :get, path: "/asset"}

    assert {:ok, %{body: <<1, 2, 3>>}} = LlmCall.fetch(client(), encoded)
  end

  test "a non-2xx codec that cannot decode errors still reports the status" do
    FakeHTTP.put_response({:ok, %{status: 500, headers: [], body: "oops"}})

    assert {:error, %Error{kind: :transport, status: 500}} =
             LlmCall.generate(client(), request(), codec: :images)
  end
end
