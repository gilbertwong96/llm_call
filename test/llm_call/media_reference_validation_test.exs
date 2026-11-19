defmodule LlmCall.MediaReferenceValidationTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Content, Error}
  alias LlmCall.Media.Request

  defp request(overrides \\ []) do
    struct(
      %Request{
        modality: :video,
        model: "seedance-1-0-pro-250528",
        prompt: "p",
        references: [%Content.Image{source: {:base64, nil}, media_type: "image/png"}]
      },
      overrides
    )
  end

  test "Seedance rejects a base64 reference without bytes" do
    assert {:error, %Error{kind: :validation}} =
             LlmCall.Media.Protocol.Seedance.Video.validate_request(request(), %Config{})
  end

  test "MiniMax rejects a base64 reference without bytes" do
    assert {:error, %Error{kind: :validation}} =
             LlmCall.Media.Protocol.MiniMax.Video.validate_request(
               request(model: "MiniMax-Hailuo-2.3"),
               %Config{}
             )
  end
end
