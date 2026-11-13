defmodule LlmCall.Media.Protocol.Gemini.Predict do
  @moduledoc """
  Gemini Imagen image generation (`POST /v1beta/models/{model}:predict`).

  Instances carry the prompt; media controls live under `parameters`. `size`,
  `seed`, and `duration_s` are rejected because this endpoint does not expose
  them, and `references` are rejected because the JSON body cannot carry an
  upload.

  `model` must be a bare model id: it is interpolated into the request path.
  """

  alias LlmCall.{Codec, Config, Content, EncodedRequest, Error}
  alias LlmCall.Media.Capabilities, as: MediaCapabilities
  alias LlmCall.Media.Request, as: MediaRequest
  alias LlmCall.Media.Response, as: MediaResponse

  alias LlmCall.Protocol.Helpers

  @behaviour LlmCall.Media.Codec

  @codec :gemini_predict
  @api_version "v1beta"
  @headers [{"content-type", "application/json"}]
  @reserved_keys ~w(model prompt instances modality)
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
  @spec capabilities(MediaRequest.t(), Config.t()) :: MediaCapabilities.t()
  def capabilities(%MediaRequest{}, %Config{}) do
    %MediaCapabilities{
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
  @spec validate_request(MediaRequest.t(), Config.t()) :: :ok | {:error, Error.t()}
  def validate_request(%MediaRequest{} = request, %Config{} = config) do
    with :ok <- validate_modality(request.modality),
         :ok <- validate_model(request.model),
         :ok <- validate_prompt(request.prompt),
         :ok <- validate_params(request.params),
         :ok <- validate_references(request.references),
         :ok <- validate_provider_options(request, config) do
      :ok
    end
  end

  @impl true
  @spec encode_submit(MediaRequest.t(), Config.t()) ::
          {:ok, EncodedRequest.t()} | {:error, Error.t()}
  def encode_submit(%MediaRequest{} = request, %Config{} = config) do
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
          {:ok, MediaResponse.t()} | {:error, Error.t()}
  def decode_submit(%{"predictions" => [_ | _] = predictions} = payload, %Config{} = config)
      when is_list(predictions) do
    with {:ok, assets} <- decode_predictions(predictions, payload) do
      {:ok,
       %MediaResponse{
         assets: assets,
         revised_prompt: nil,
         usage: nil,
         operation: nil,
         raw: capture_response(config, payload)
       }}
    end
  end

  def decode_submit(_term, _config) do
    {:error, invalid_response("response has no predictions")}
  end

  @impl true
  @spec decode_error(LlmCall.wire_value(), Config.t()) :: Error.t()
  def decode_error(%{"error" => %{"message" => message} = error} = payload, %Config{}) do
    status = error["status"]

    %Error{
      kind: :provider,
      message: message,
      code: status,
      status: nil,
      retryable?: status in @retryable_statuses,
      raw: payload
    }
  end

  def decode_error(_term, _config) do
    %Error{
      kind: :invalid_response,
      message: "gemini_predict: unrecognized error payload",
      raw: nil
    }
  end

  defp decode_predictions(predictions, payload) do
    usable = Enum.filter(predictions, &valid_prediction?/1)

    cond do
      usable != [] ->
        {:ok, Enum.map(usable, &decode_asset/1)}

      filtered? = Enum.find(predictions, &filtered?/1) ->
        {:error, %Error{kind: :provider, message: filtered?["raiFilteredReason"], raw: payload}}

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

  defp validate_modality(:image), do: :ok

  defp validate_modality(modality) do
    Helpers.error(@codec, "modality must be :image, got: #{inspect(modality)}")
  end

  defp validate_model(model) when is_binary(model) and model != "" do
    if String.contains?(model, ["/", ":"]) do
      Helpers.error(@codec, "model must be a bare model id without \"/\" or \":\"")
    else
      :ok
    end
  end

  defp validate_model(_model), do: Helpers.error(@codec, "model is required")

  defp validate_prompt(prompt) when is_binary(prompt) and prompt != "", do: :ok
  defp validate_prompt(_prompt), do: Helpers.error(@codec, "prompt is required")

  defp validate_params(params) when is_map(params) do
    present = for {key, value} <- params, not is_nil(value), do: key

    with :ok <-
           Helpers.first_error(present, fn key ->
             if key in @param_keys,
               do: :ok,
               else: Helpers.error(@codec, "params key #{inspect(key)} is not supported")
           end),
         :ok <- validate_n(params[:n]),
         :ok <- validate_aspect_ratio(params[:aspect_ratio]) do
      :ok
    end
  end

  defp validate_params(_params), do: Helpers.error(@codec, "params must be a map")

  defp validate_n(nil), do: :ok

  defp validate_n(n) when is_integer(n) and n > 0 and n <= @max_n, do: :ok

  defp validate_n(_n), do: Helpers.error(@codec, "params.n must be between 1 and #{@max_n}")

  defp validate_aspect_ratio(nil), do: :ok
  defp validate_aspect_ratio(ratio) when ratio in @aspect_ratios, do: :ok

  defp validate_aspect_ratio(_ratio),
    do: Helpers.error(@codec, "params.aspect_ratio must be one of #{inspect(@aspect_ratios)}")

  defp validate_references(nil), do: :ok
  defp validate_references([]), do: :ok

  defp validate_references(_references) do
    Helpers.error(@codec, "references require an upload and are not supported")
  end

  defp validate_provider_options(request, config) do
    case provider_options(request, config) do
      options when is_map(options) ->
        Helpers.first_error(Map.keys(options), fn key ->
          if Helpers.reserved_key?(key, @reserved_keys) do
            Helpers.error(
              @codec,
              "provider option #{inspect(key)} would replace a canonical field"
            )
          else
            :ok
          end
        end)

      _options ->
        Helpers.error(@codec, "provider_options.gemini must be a map")
    end
  end

  defp provider_options(request, config) do
    options = Config.provider_options(request, config)
    Map.get(options, :gemini) || Map.get(options, :google) || %{}
  end

  defp capture_response(%Config{capture_raw: raw}, term) when raw in [:response, :all], do: term
  defp capture_response(_config, _term), do: nil

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "gemini_predict: " <> message}
  end
end
