defmodule LlmDialect.Media.Protocol.MiniMax.Video do
  @moduledoc """
  MiniMax Hailuo video generation (`v1`).

  Three calls, expressed with the `Operation` state machine:

  1. submit `POST /v1/video_generation` -> `task_id`;
  2. poll `GET /v1/query/video_generation?task_id=…` -> `Preparing` /
     `Queueing` / `Processing` / `Success` / `Fail`;
  3. on `Success` the query returns only a `file_id`, so the operation stays
     `:in_progress` and `next` is `GET /v1/files/retrieve?file_id=…`; that payload
     carries `file.download_url`, which completes the job.

  MiniMax reports errors as HTTP 200 with a non-zero `base_resp.status_code`, so
  a non-zero `base_resp` is a `:provider` error regardless of transport status.

  `resolution`, `prompt_optimizer`, `fast_pretreatment`, `callback_url`, and
  `extra` are reached through `provider_options.minimax`. The `v2` (H3) surface
  is not implemented.
  """

  alias LlmDialect.{Codec, Config, Content, EncodedRequest, Error, Operation}
  alias LlmDialect.Media.Capabilities, as: MediaCapabilities
  alias LlmDialect.Media.Request, as: MediaRequest
  alias LlmDialect.Media.Response, as: MediaResponse

  alias LlmDialect.Protocol.Helpers

  @behaviour LlmDialect.Media.Codec

  @codec :minimax_video
  @api_version "v1"
  @submit_path "/v1/video_generation"
  @query_path "/v1/query/video_generation"
  @retrieve_path "/v1/files/retrieve"
  @headers [{"content-type", "application/json"}]
  @reserved_keys ~w(model prompt content instances parameters modality)
  @param_keys [:duration_s]
  @durations [6, 10]
  @retryable_codes ~w(1001 1002 1013 1039)

  @impl true
  @spec info() :: Codec.Info.t()
  def info do
    %Codec.Info{name: @codec, protocol: @codec, version: @api_version, ir_version: 1}
  end

  @impl true
  @spec capabilities(MediaRequest.t(), Config.t()) :: MediaCapabilities.t()
  def capabilities(%MediaRequest{}, %Config{}) do
    %MediaCapabilities{
      modalities: [:video],
      async: true,
      max_n: :unsupported,
      sizes: [],
      aspect_ratios: [],
      durations_s: @durations,
      max_references: 1,
      seed: false,
      negative_prompt: false
    }
  end

  @impl true
  @spec validate_request(MediaRequest.t(), Config.t()) :: :ok | {:error, Error.t()}
  def validate_request(%MediaRequest{} = request, %Config{} = config) do
    with :ok <- validate_modality(request.modality),
         :ok <- validate_model(request.model),
         :ok <- validate_prompt(request.prompt),
         :ok <- validate_params(request.params),
         :ok <- validate_references(request.references) do
      validate_provider_options(request, config)
    end
  end

  @impl true
  @spec encode_submit(MediaRequest.t(), Config.t()) ::
          {:ok, EncodedRequest.t()} | {:error, Error.t()}
  def encode_submit(%MediaRequest{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      body =
        %{"model" => request.model, "prompt" => request.prompt}
        |> Helpers.maybe_put("duration", request.params[:duration_s])
        |> Helpers.maybe_put("first_frame_image", first_frame_image(request.references))
        |> Config.deep_merge(provider_options(request, config))

      {:ok, Helpers.post(@submit_path, @headers, body)}
    end
  end

  @impl true
  @spec decode_submit(LlmDialect.wire_value(), Config.t()) ::
          {:ok, MediaResponse.t()} | {:error, Error.t()}
  def decode_submit(payload, %Config{} = config) when is_map(payload) do
    with :ok <- check_base_resp(payload),
         {:ok, task_id} <- fetch_task_id(payload) do
      {:ok,
       %MediaResponse{
         assets: [],
         operation: %Operation{
           id: task_id,
           status: :queued,
           next: query_request(task_id),
           next_kind: :poll
         },
         raw: Helpers.capture_response(config, payload)
       }}
    end
  end

  def decode_submit(_term, _config) do
    {:error, invalid_response("submit response is not an object")}
  end

  @impl true
  @spec decode_operation(LlmDialect.wire_value(), Config.t()) ::
          {:ok, Operation.t()} | {:error, Error.t()}
  def decode_operation(%{"status" => "Fail"} = payload, %Config{} = config) do
    base_resp = if is_map(payload["base_resp"]), do: payload["base_resp"], else: %{}

    {:ok,
     %Operation{
       id: payload["task_id"],
       status: :failed,
       error: %Error{
         kind: :provider,
         message: base_resp["status_msg"] || "task failed",
         code: Helpers.code(base_resp["status_code"] || "Fail"),
         raw: payload
       },
       raw: Helpers.capture_response(config, payload)
     }}
  end

  def decode_operation(payload, %Config{} = config) when is_map(payload) do
    with :ok <- check_base_resp(payload) do
      case payload do
        %{"file" => %{"download_url" => url}} when is_binary(url) and url != "" ->
          {:ok, completed_operation(url, payload, config)}

        %{"status" => "Success"} ->
          success_operation(payload, config)

        %{"status" => status} when status in ["Preparing", "Queueing", "Processing"] ->
          in_progress_operation(payload, config)

        _other ->
          {:error, invalid_response("payload is neither a task status nor a file record")}
      end
    end
  end

  def decode_operation(_term, _config) do
    {:error, invalid_response("payload is not an object")}
  end

  @impl true
  @spec decode_error(LlmDialect.wire_value(), Config.t()) :: Error.t()
  def decode_error(payload, %Config{}) when is_map(payload) do
    case check_base_resp(payload) do
      {:error, error} -> error
      :ok -> %Error{kind: :invalid_response, message: "minimax_video: unrecognized error payload"}
    end
  end

  def decode_error(_term, %Config{}) do
    %Error{kind: :invalid_response, message: "minimax_video: unrecognized error payload"}
  end

  defp success_operation(payload, config) do
    case payload["file_id"] do
      file_id when is_binary(file_id) and file_id != "" ->
        {:ok, in_progress_with(payload, retrieve_request(file_id), config)}

      file_id when is_integer(file_id) ->
        {:ok, in_progress_with(payload, retrieve_request(file_id), config)}

      _absent ->
        {:error, invalid_response("Success response has no file_id")}
    end
  end

  defp in_progress_operation(payload, config) do
    with {:ok, task_id} <- fetch_task_id(payload) do
      {:ok, in_progress_with(payload, query_request(task_id), config)}
    end
  end

  defp in_progress_with(payload, next, config) do
    %Operation{
      id: payload["task_id"],
      status: :in_progress,
      next: next,
      next_kind: :poll,
      raw: Helpers.capture_response(config, payload)
    }
  end

  defp completed_operation(url, payload, config) do
    %Operation{
      id: nil,
      status: :completed,
      result: %MediaResponse{
        assets: [%Content.Video{source: {:url, url}, media_type: "video/mp4"}]
      },
      raw: Helpers.capture_response(config, payload)
    }
  end

  defp fetch_task_id(%{"task_id" => task_id}) when is_binary(task_id) and task_id != "",
    do: {:ok, task_id}

  defp fetch_task_id(_payload), do: {:error, invalid_response("submit response has no task id")}

  defp check_base_resp(payload) do
    case payload["base_resp"] do
      %{"status_code" => code} = base_resp when is_integer(code) and code != 0 ->
        {:error,
         %Error{
           kind: :provider,
           message: base_resp["status_msg"] || "provider error",
           code: Helpers.code(code),
           retryable?: Helpers.retryable?(Helpers.code(code), @retryable_codes),
           raw: payload
         }}

      _ok_or_absent ->
        :ok
    end
  end

  defp query_request(task_id) do
    %EncodedRequest{
      method: :get,
      path: @query_path,
      query: %{"task_id" => to_string(task_id)},
      headers: @headers,
      body: %{}
    }
  end

  defp retrieve_request(file_id) do
    %EncodedRequest{
      method: :get,
      path: @retrieve_path,
      query: %{"file_id" => to_string(file_id)},
      headers: @headers,
      body: %{}
    }
  end

  defp first_frame_image([]), do: nil
  defp first_frame_image(nil), do: nil

  defp first_frame_image([%Content.Image{source: {:url, url}} | _rest]), do: url
  defp first_frame_image([%Content.Image{source: url} | _rest]) when is_binary(url), do: url

  defp first_frame_image([
         %Content.Image{source: {:base64, data}, media_type: media_type} | _rest
       ]) do
    "data:#{media_type};base64,#{data}"
  end

  defp validate_modality(:video), do: :ok

  defp validate_modality(modality) do
    Helpers.error(@codec, "modality must be :video, got: #{inspect(modality)}")
  end

  defp validate_model(model) when is_binary(model) and model != "", do: :ok
  defp validate_model(_model), do: Helpers.error(@codec, "model is required")

  defp validate_prompt(prompt) when is_binary(prompt) and prompt != "", do: :ok
  defp validate_prompt(_prompt), do: Helpers.error(@codec, "prompt is required")

  defp validate_params(params) when is_map(params) do
    with :ok <- Helpers.validate_param_keys(params, @param_keys, @codec) do
      validate_duration(params[:duration_s])
    end
  end

  defp validate_params(_params), do: Helpers.error(@codec, "params must be a map")

  defp validate_duration(nil), do: :ok
  defp validate_duration(duration) when duration in @durations, do: :ok

  defp validate_duration(_duration),
    do: Helpers.error(@codec, "params.duration_s must be one of #{inspect(@durations)}")

  defp validate_references(nil), do: :ok
  defp validate_references([]), do: :ok
  defp validate_references([reference]), do: validate_reference(reference)

  defp validate_references(references) when is_list(references) do
    Helpers.error(@codec, "at most one first-frame reference image is supported")
  end

  defp validate_references(_references), do: Helpers.error(@codec, "references must be a list")

  defp validate_reference(%Content.Image{source: {:url, url}}) when is_binary(url), do: :ok
  defp validate_reference(%Content.Image{source: source}) when is_binary(source), do: :ok

  defp validate_reference(%Content.Image{source: {:base64, _data}, media_type: nil}),
    do: Helpers.error(@codec, "base64 reference requires media_type")

  defp validate_reference(%Content.Image{source: {:base64, _data}}), do: :ok

  defp validate_reference(%Content.Image{}),
    do: Helpers.error(@codec, "reference image source is not supported")

  defp validate_reference(_part),
    do: Helpers.error(@codec, "only an image reference is supported")

  defp validate_provider_options(request, config) do
    case provider_options(request, config) do
      options when is_map(options) ->
        Helpers.validate_option_keys(options, @reserved_keys, @codec)

      _options ->
        Helpers.error(@codec, "provider_options.minimax must be a map")
    end
  end

  defp provider_options(request, config) do
    Config.provider_options(request, config) |> Map.get(:minimax, %{})
  end

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "minimax_video: " <> message}
  end
end
