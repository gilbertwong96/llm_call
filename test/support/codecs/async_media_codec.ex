defmodule LlmCall.TestCodec.AsyncMedia do
  @moduledoc """
  Asynchronous media codec fake. Honours its own capability declarations and drives the `Operation` state machine through every state.
  """
  @behaviour LlmCall.Media.Codec

  alias LlmCall.{Codec, Content, EncodedRequest, Error, Operation}
  alias LlmCall.Media.Capabilities, as: MediaCapabilities
  alias LlmCall.Media.Request, as: MediaRequest
  alias LlmCall.Media.Response, as: MediaResponse

  @poll %EncodedRequest{method: :get, path: "/fake/jobs/1"}

  @impl true
  def info,
    do: %Codec.Info{name: :async_media, protocol: :async_media, version: nil, ir_version: 1}

  @impl true
  def capabilities(_request, _config),
    do: %MediaCapabilities{modalities: [:video], async: true, max_references: nil}

  @impl true
  def validate_request(%MediaRequest{} = request, _config) do
    params = request.params

    cond do
      request.modality != :video ->
        {:error, %Error{kind: :validation, message: "async_media: modality"}}

      Map.has_key?(params, :n) ->
        {:error, %Error{kind: :validation, message: "async_media: n"}}

      Map.has_key?(params, :seed) ->
        {:error, %Error{kind: :validation, message: "async_media: seed"}}

      Map.has_key?(params, :negative_prompt) ->
        {:error, %Error{kind: :validation, message: "async_media: negative_prompt"}}

      Enum.any?([:size, :aspect_ratio, :duration_s], &Map.has_key?(params, &1)) ->
        {:error, %Error{kind: :validation, message: "async_media: undeclared param"}}

      request.references != [] ->
        {:error, %Error{kind: :validation, message: "async_media: references"}}

      true ->
        :ok
    end
  end

  @impl true
  def encode_submit(_request, _config),
    do: {:ok, %EncodedRequest{method: :post, path: "/fake/jobs"}}

  @impl true
  def decode_submit(_payload, _config) do
    {:ok,
     %MediaResponse{
       assets: [],
       operation: %Operation{id: "job_1", status: :queued, next: @poll, next_kind: :poll}
     }}
  end

  @impl true
  def decode_operation(%{"status" => "in_progress"} = payload, config) do
    {:ok,
     %Operation{
       id: "job_1",
       status: :in_progress,
       progress: 40,
       next: @poll,
       next_kind: :poll,
       raw: if(config.capture_raw == :none, do: nil, else: payload)
     }}
  end

  def decode_operation(%{"status" => "completed", "url" => url} = payload, config) do
    {:ok,
     %Operation{
       id: "job_1",
       status: :completed,
       result: %MediaResponse{
         assets: [%Content.Video{source: {:url, url}, media_type: "video/mp4"}]
       },
       raw: if(config.capture_raw == :none, do: nil, else: payload)
     }}
  end

  def decode_operation(%{"status" => "completed", "asset_path" => path} = payload, config) do
    {:ok,
     %Operation{
       id: "job_1",
       status: :completed,
       result: %MediaResponse{assets: []},
       next: %EncodedRequest{method: :get, path: path},
       next_kind: :asset,
       next_media_type: "video/mp4",
       raw: if(config.capture_raw == :none, do: nil, else: payload)
     }}
  end

  def decode_operation(%{"status" => "failed", "message" => message}, _config) do
    {:ok,
     %Operation{id: "job_1", status: :failed, error: %Error{kind: :provider, message: message}}}
  end

  @impl true
  def decode_error(_term, _config), do: %Error{kind: :provider, message: "async_media error"}
end
