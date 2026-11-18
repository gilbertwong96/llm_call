defmodule LlmCall.Media.Protocol.Seedance.Video do
  @moduledoc """
  Seedance video generation (BytePlus ModelArk content generation tasks).


  Submit `POST /api/v3/contents/generations/tasks`, then poll
  `GET /api/v3/contents/generations/tasks/{id}`. The prompt and any reference
  images are `content` parts; `ratio`, `duration`, and `seed` are top-level.

  Native knobs this canonical layer has no field for (`resolution`, `watermark`,
  `generate_audio`, `camera_fixed`, `service_tier`, `return_last_frame`) are
  reached through `provider_options.seedance`.

  `durations_s` declares the range this codec accepts; the core has no model
  catalog, so a model-specific limit surfaces as a provider error.
  """

  use LlmCall.Media.Adapter, codec: :seedance_video, modality: :video, namespaces: [:seedance]

  @api_version "v3"
  @path "/api/v3/contents/generations/tasks"
  @headers [{"content-type", "application/json"}]
  @reserved_keys ~w(model content ratio duration seed)
  @param_keys [:aspect_ratio, :duration_s, :seed]
  @ratios ["adaptive", "1:1", "4:3", "3:4", "16:9", "9:16", "21:9"]
  # Union across Seedance models: 1.0 accepts 2-12 s, 1.5 pro 4-12 s, 2.0 4-15 s,
  # 2.5 4-30 s. A model-specific limit surfaces as a provider error.
  @durations Enum.to_list(2..30)
  @max_references 2
  @retryable_codes ~w(InternalServiceError RateLimitExceeded)

  @impl true
  @spec info() :: Codec.Info.t()
  def info do
    %Codec.Info{name: @codec, protocol: @codec, version: @api_version, ir_version: 1}
  end

  @impl true
  @spec capabilities(Request.t(), Config.t()) :: Capabilities.t()
  def capabilities(%Request{}, %Config{}) do
    %Capabilities{
      modalities: [:video],
      async: true,
      max_n: :unsupported,
      sizes: [],
      aspect_ratios: @ratios,
      durations_s: @durations,
      max_references: @max_references,
      seed: true,
      negative_prompt: false
    }
  end

  @impl true
  @spec encode_submit(Request.t(), Config.t()) ::
          {:ok, EncodedRequest.t()} | {:error, Error.t()}
  def encode_submit(%Request{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      body =
        %{
          "model" => request.model,
          "content" => [%{"type" => "text", "text" => request.prompt}] ++ reference_parts(request)
        }
        |> Helpers.maybe_put("ratio", request.params[:aspect_ratio])
        |> Helpers.maybe_put("duration", request.params[:duration_s])
        |> Helpers.maybe_put("seed", request.params[:seed])
        |> Config.deep_merge(provider_options(request, config))

      {:ok, Helpers.post(@path, @headers, body)}
    end
  end

  @impl true
  @spec decode_submit(LlmCall.wire_value(), Config.t()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def decode_submit(%{"id" => id} = payload, %Config{} = config)
      when is_binary(id) and id != "" do
    {:ok,
     %Response{
       assets: [],
       operation: %Operation{
         id: id,
         status: :queued,
         next: poll_request(id),
         next_kind: :poll
       },
       raw: Helpers.capture_response(config, payload)
     }}
  end

  def decode_submit(_term, _config) do
    {:error, invalid_response("submit response has no task id")}
  end

  @impl true
  @spec decode_operation(LlmCall.wire_value(), Config.t()) ::
          {:ok, Operation.t()} | {:error, Error.t()}
  def decode_operation(%{"status" => status} = payload, %Config{} = config)
      when is_binary(status) do
    case status do
      "queued" ->
        in_progress_operation(payload, :queued, config)

      "running" ->
        in_progress_operation(payload, :in_progress, config)

      "succeeded" ->
        completed_operation(payload, config)

      terminal when terminal in ["failed", "cancelled", "expired"] ->
        {:ok, failed_operation(payload, terminal, config)}

      _other ->
        {:error, invalid_response("unrecognized task status #{inspect(status)}")}
    end
  end

  def decode_operation(_term, _config) do
    {:error, invalid_response("payload has no task status")}
  end

  @impl true
  @spec decode_error(LlmCall.wire_value(), Config.t()) :: Error.t()
  def decode_error(payload, _config) do
    Helpers.decode_provider_error(payload, @codec, ["code", "type"], @retryable_codes)
  end

  defp in_progress_operation(payload, status, config) do
    with {:ok, id} <- fetch_id(payload) do
      {:ok,
       %Operation{
         id: id,
         status: status,
         next: poll_request(id),
         next_kind: :poll,
         raw: Helpers.capture_response(config, payload)
       }}
    end
  end

  defp fetch_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_id(_payload), do: {:error, invalid_response("task payload has no id")}

  defp completed_operation(payload, config) do
    case get_in(payload, ["content", "video_url"]) do
      url when is_binary(url) and url != "" ->
        {:ok,
         %Operation{
           id: payload["id"],
           status: :completed,
           result: %Response{
             assets: [%Content.Video{source: {:url, url}, media_type: "video/mp4"}]
           },
           raw: Helpers.capture_response(config, payload)
         }}

      _absent ->
        {:error, invalid_response("succeeded task has no video url")}
    end
  end

  defp failed_operation(payload, terminal, config) do
    error = if is_map(payload["error"]), do: payload["error"], else: %{}

    %Operation{
      id: payload["id"],
      status: :failed,
      error: %Error{
        kind: :provider,
        message: error["message"] || "task #{terminal}",
        code: error["code"] || terminal,
        raw: payload
      },
      raw: Helpers.capture_response(config, payload)
    }
  end

  defp poll_request(id) do
    %EncodedRequest{
      method: :get,
      path: @path <> "/" <> id,
      query: %{},
      headers: @headers,
      body: %{}
    }
  end

  defp reference_parts(%Request{references: references}) do
    references
    |> Enum.with_index()
    |> Enum.map(fn {reference, index} -> image_part(image_url(reference), frame_role(index)) end)
  end

  defp image_url(%Content.Image{source: {:url, url}}), do: url
  defp image_url(%Content.Image{source: source}) when is_binary(source), do: source

  defp image_url(%Content.Image{source: {:base64, data}, media_type: media_type}) do
    "data:#{media_type};base64,#{data}"
  end

  # ModelArk needs an explicit role for the first/last-frame pair.
  defp frame_role(0), do: "first_frame"
  defp frame_role(_last), do: "last_frame"

  defp image_part(url, role) do
    %{"type" => "image_url", "image_url" => %{"url" => url}, "role" => role}
  end

  defp validate_params(params) when is_map(params) do
    with :ok <- Helpers.validate_param_keys(params, @param_keys, @codec),
         :ok <- validate_ratio(params[:aspect_ratio]),
         :ok <- validate_duration(params[:duration_s]) do
      validate_seed(params[:seed])
    end
  end

  defp validate_params(_params), do: Helpers.error(@codec, "params must be a map")

  defp validate_ratio(nil), do: :ok
  defp validate_ratio(ratio) when ratio in @ratios, do: :ok

  defp validate_ratio(_ratio),
    do: Helpers.error(@codec, "params.aspect_ratio must be one of #{inspect(@ratios)}")

  defp validate_duration(nil), do: :ok
  defp validate_duration(duration) when duration in @durations, do: :ok

  defp validate_duration(_duration) do
    Helpers.error(
      @codec,
      "params.duration_s must be between #{List.first(@durations)} and #{List.last(@durations)}"
    )
  end

  defp validate_seed(nil), do: :ok
  defp validate_seed(seed) when is_integer(seed) and seed >= 0, do: :ok

  defp validate_seed(_seed),
    do: Helpers.error(@codec, "params.seed must be a non-negative integer")

  defp validate_references(nil), do: :ok
  defp validate_references([]), do: :ok

  defp validate_references(references) when is_list(references) do
    with :ok <- validate_reference_count(references) do
      Helpers.first_error(references, &validate_reference/1)
    end
  end

  defp validate_references(_references), do: Helpers.error(@codec, "references must be a list")

  defp validate_reference_count(references) when length(references) <= @max_references, do: :ok

  defp validate_reference_count(_references) do
    Helpers.error(@codec, "at most #{@max_references} reference images are supported")
  end

  defp validate_reference(%Content.Image{source: {:url, url}}) when is_binary(url), do: :ok
  defp validate_reference(%Content.Image{source: source}) when is_binary(source), do: :ok

  defp validate_reference(%Content.Image{source: {:base64, _data}, media_type: nil}),
    do: Helpers.error(@codec, "base64 reference requires media_type")

  defp validate_reference(%Content.Image{source: {:base64, _data}}), do: :ok

  defp validate_reference(%Content.Image{}),
    do: Helpers.error(@codec, "reference image source is not supported")

  defp validate_reference(_part), do: Helpers.error(@codec, "only image references are supported")

  defp validate_provider_options(request, config) do
    case provider_options(request, config) do
      options when is_map(options) ->
        Helpers.validate_option_keys(options, @reserved_keys, @codec)

      _options ->
        Helpers.error(@codec, "provider_options.seedance must be a map")
    end
  end

  defp provider_options(request, config) do
    Config.provider_options(request, config) |> Map.get(:seedance, %{})
  end

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "seedance_video: " <> message}
  end
end
