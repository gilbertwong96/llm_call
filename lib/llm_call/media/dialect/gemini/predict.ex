defmodule LlmCall.Media.Dialect.Gemini.Predict do
  @moduledoc """
  Gemini Imagen image generation (`POST /v1beta/models/{model}:predict`).


  Instances carry the prompt; media controls live under `parameters`. `size`,
  `seed`, and `duration_s` are rejected because this endpoint does not expose
  them, and `references` are rejected because the JSON body cannot carry an
  upload.

  `model` must be a bare model id: it is interpolated into the request path.

  A filtered prediction carries `raiFilteredReason` instead of image bytes; it is
  skipped while another prediction has bytes and becomes a `:provider` error when
  none do. Without `includeRaiReason` in `provider_options.gemini["parameters"]`
  the provider omits filtered images altogether, so an empty `predictions` array
  means everything was blocked rather than that the payload was malformed.
  """

  use LlmCall.Media.Dialect.Adapter,
    codec: :gemini_predict,
    modality: :image,
    namespaces: [:gemini, :google],
    model_fun: &Helpers.validate_model_id/2

  @api_version "v1beta"
  @headers [{"content-type", "application/json"}]
  @reserved_keys ~w(model prompt instances)
  @param_keys [:n, :aspect_ratio, :negative_prompt]
  @aspect_ratios ["1:1", "3:4", "4:3", "9:16", "16:9"]
  @max_n 4
  @retryable_statuses ~w(RESOURCE_EXHAUSTED UNAVAILABLE INTERNAL DEADLINE_EXCEEDED)

  @impl true
  @spec info() :: Codec.Info.t()
  def info do
    %Codec.Info{name: @codec, protocol: @codec, version: @api_version, ir_version: 1}
  end

  @impl true
  @spec capabilities(Request.t(), Config.t()) :: Capabilities.t()
  def capabilities(%Request{}, %Config{}) do
    %Capabilities{
      modalities: [:image],
      async: false,
      max_n: @max_n,
      sizes: [],
      aspect_ratios: @aspect_ratios,
      durations_s: [],
      max_references: nil,
      seed: false,
      negative_prompt: true
    }
  end

  @impl true
  @spec encode_submit(Request.t(), Config.t()) ::
          {:ok, EncodedRequest.t()} | {:error, Error.t()}
  def encode_submit(%Request{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      body =
        %{"instances" => [%{"prompt" => request.prompt}]}
        |> put_parameters(request.params)
        |> Config.deep_merge(provider_options(request, config))

      {:ok,
       %EncodedRequest{
         method: :post,
         path: "/v1beta/models/#{request.model}:predict",
         query: %{},
         headers: @headers,
         body: body
       }}
    end
  end

  @impl true
  @spec decode_submit(LlmCall.wire_value(), Config.t()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def decode_submit(%{"predictions" => [_ | _] = predictions} = payload, %Config{} = config)
      when is_list(predictions) do
    with {:ok, assets} <- decode_predictions(predictions, payload, config) do
      {:ok,
       %Response{
         assets: assets,
         revised_prompt: nil,
         usage: nil,
         operation: nil,
         raw: Helpers.capture_response(config, payload)
       }}
    end
  end

  def decode_submit(_term, _config) do
    {:error, invalid_response("response has no predictions")}
  end

  @impl true
  @spec decode_error(LlmCall.wire_value(), Config.t()) :: Error.t()
  def decode_error(%{"error" => %{"message" => message} = error} = payload, %Config{} = config) do
    status = Helpers.code(error["status"])

    %Error{
      kind: :provider,
      message: message,
      code: status,
      status: nil,
      retryable?: Helpers.retryable?(status, @retryable_statuses),
      raw: Helpers.capture_response(config, payload)
    }
  end

  def decode_error(_term, _config) do
    %Error{
      kind: :invalid_response,
      message: "gemini_predict: unrecognized error payload",
      raw: nil
    }
  end

  defp decode_predictions(predictions, payload, config) do
    usable = Enum.filter(predictions, &valid_prediction?/1)

    cond do
      usable != [] ->
        {:ok, Enum.map(usable, &decode_asset/1)}

      filtered? = Enum.find(predictions, &filtered?/1) ->
        {:error,
         %Error{
           kind: :provider,
           message: filtered?["raiFilteredReason"],
           raw: Helpers.capture_response(config, payload)
         }}

      true ->
        {:error, invalid_response("prediction has no image bytes")}
    end
  end

  defp filtered?(%{"raiFilteredReason" => reason}) when is_binary(reason), do: true
  defp filtered?(_prediction), do: false

  defp valid_prediction?(%{"bytesBase64Encoded" => data}) when is_binary(data), do: true
  defp valid_prediction?(_prediction), do: false

  defp decode_asset(%{"bytesBase64Encoded" => data} = prediction) do
    %Content.Image{
      source: {:base64, data},
      media_type: prediction["mimeType"] || "image/png"
    }
  end

  defp put_parameters(body, params) do
    parameters =
      %{}
      |> Helpers.maybe_put("sampleCount", params[:n])
      |> Helpers.maybe_put("aspectRatio", params[:aspect_ratio])
      |> Helpers.maybe_put("negativePrompt", params[:negative_prompt])

    case parameters do
      empty when map_size(empty) == 0 -> body
      parameters -> Map.put(body, "parameters", parameters)
    end
  end

  defp validate_params(params) when is_map(params) do
    with :ok <- Helpers.validate_param_keys(params, @param_keys, @codec),
         :ok <- validate_n(params[:n]),
         :ok <- validate_aspect_ratio(params[:aspect_ratio]) do
      validate_negative_prompt(params[:negative_prompt])
    end
  end

  defp validate_params(_params), do: Helpers.error(@codec, "params must be a map")

  defp validate_n(n), do: Helpers.validate_n(n, @max_n, @codec)

  defp validate_aspect_ratio(nil), do: :ok
  defp validate_aspect_ratio(ratio) when ratio in @aspect_ratios, do: :ok

  defp validate_aspect_ratio(_ratio),
    do: Helpers.error(@codec, "params.aspect_ratio must be one of #{inspect(@aspect_ratios)}")

  defp validate_negative_prompt(nil), do: :ok
  defp validate_negative_prompt(prompt) when is_binary(prompt), do: :ok

  defp validate_negative_prompt(_prompt),
    do: Helpers.error(@codec, "params.negative_prompt must be a string")

  defp validate_references(nil), do: :ok
  defp validate_references([]), do: :ok

  defp validate_references(_references) do
    Helpers.error(@codec, "references require an upload and are not supported")
  end

  defp validate_provider_options(request, config) do
    options = provider_options(request, config)

    with :ok <- Helpers.validate_option_keys(options, @reserved_keys, @codec) do
      validate_parameters(options)
    end
  end

  defp validate_parameters(%{"parameters" => parameters}) when is_map(parameters) do
    Helpers.validate_option_keys(
      parameters,
      ["samplecount", "aspectratio", "negativeprompt"],
      @codec
    )
  end

  defp validate_parameters(%{"parameters" => _other}) do
    Helpers.error(@codec, "provider_options.parameters must be a map")
  end

  defp validate_parameters(_options), do: :ok

  defp provider_options(request, config) do
    Helpers.alias_options(
      config.default_provider_options,
      request.provider_options,
      :gemini,
      :google
    )
  end

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "gemini_predict: " <> message}
  end
end
