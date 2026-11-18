defmodule LlmCall.DecodePathAuditTest do
  @moduledoc """
  Enumerates every provider field in a decoded payload and proves it is either
  mapped or explicitly ignored.

  The encode side has reserved keys to check; the decode side has no such
  structure, so the audit is a mutation one: delete one provider leaf at a time,
  decode again, and compare the canonical result. A deletion that changes nothing
  means the field is not read — either it is an envelope/echo field we never
  model, or it is a silent drop. `@cases` carries the allowlist, so adding a field
  to a fixture without mapping it fails here.

  The same run asserts nil-safety: no single missing field may raise.

  Two blind spots this audit found are pinned in the protocol suites instead,
  because the fixture value happened to equal the fallback:
  `tool_calls[].index` (OpenAI, differs from the choice index) and `mimeType`
  (Gemini Imagen, differs from the `image/png` default).
  """

  use ExUnit.Case, async: true

  alias LlmCall.Config

  defp cases do
    [
      %{
        name: :openai_text,
        codec: LlmCall.Protocol.OpenAI.Chat,
        kind: :response,
        payload: LlmCall.Fixtures.OpenAIChat.text_response(),
        ignored: [
          # envelope
          ["object"],
          # choice index is an echo; the first choice is the response
          ["choices", "index"],
          # the assistant role is implied by the IR
          ["choices", "message", "role"]
        ]
      },
      %{
        name: :openai_tool_call,
        codec: LlmCall.Protocol.OpenAI.Chat,
        kind: :response,
        payload: LlmCall.Fixtures.OpenAIChat.tool_call_response(),
        ignored: [
          ["choices", "index"],
          ["choices", "message", "role"],
          # a tool-call message carries no text
          ["choices", "message", "content"],
          # every tool call is a function
          ["choices", "message", "tool_calls", "type"]
        ]
      },
      %{
        name: :openai_reasoning,
        codec: LlmCall.Protocol.OpenAI.Chat,
        kind: :response,
        payload: LlmCall.Fixtures.OpenAIChat.reasoning_and_refusal_response(),
        ignored: [["choices", "index"], ["choices", "message", "role"]]
      },
      %{
        name: :openai_responses_text,
        codec: LlmCall.Protocol.OpenAI.Responses,
        kind: :response,
        payload: LlmCall.Fixtures.OpenAIResponses.text_response(),
        ignored: [
          # envelope and item bookkeeping the IR does not keep
          ["object"],
          ["output", "id"],
          ["output", "role"],
          ["output", "status"],
          # an empty annotation list carries no information
          ["output", "content", "annotations"]
        ]
      },
      %{
        name: :openai_responses_tool_call,
        codec: LlmCall.Protocol.OpenAI.Responses,
        kind: :response,
        payload: LlmCall.Fixtures.OpenAIResponses.tool_call_response(),
        ignored: [
          # the presence of a function call decides :tool_calls
          ["status"],
          ["output", "id"],
          ["output", "status"]
        ]
      },
      %{
        name: :openai_responses_reasoning,
        codec: LlmCall.Protocol.OpenAI.Responses,
        kind: :response,
        payload: LlmCall.Fixtures.OpenAIResponses.reasoning_response(),
        ignored: [
          # two output items, so each shared path appears once per item
          ["output", "id"],
          ["output", "id"],
          ["output", "role"],
          ["output", "status"],
          ["output", "summary", "type"],
          ["output", "content", "annotations"]
        ]
      },
      %{
        name: :anthropic_text,
        codec: LlmCall.Protocol.Anthropic.Messages,
        kind: :response,
        payload: LlmCall.Fixtures.AnthropicMessages.text_response(),
        ignored: [
          # envelope and implied role
          ["type"],
          ["role"],
          # which stop sequence matched is provider detail; the IR models the kind
          ["stop_sequence"]
        ]
      },
      %{
        name: :anthropic_mixed,
        codec: LlmCall.Protocol.Anthropic.Messages,
        kind: :response,
        payload: LlmCall.Fixtures.AnthropicMessages.mixed_response(),
        ignored: [["type"], ["role"]]
      },
      %{
        name: :gemini_text,
        codec: LlmCall.Protocol.Gemini.GenerateContent,
        kind: :response,
        payload: LlmCall.Fixtures.GeminiGenerateContent.text_response(),
        ignored: [
          # Gemini says "model"; the IR response has no role
          ["candidates", "content", "role"],
          # candidate index is an echo
          ["candidates", "index"]
        ]
      },
      %{
        name: :openai_images,
        codec: LlmCall.Media.Protocol.OpenAI.Images,
        kind: :submit,
        payload: LlmCall.Media.Fixtures.OpenAIImages.base64_response(),
        ignored: [["created"]]
      },
      %{
        name: :gemini_predict,
        codec: LlmCall.Media.Protocol.Gemini.Predict,
        kind: :submit,
        payload: LlmCall.Media.Fixtures.GeminiPredict.base64_response(),
        ignored: [
          # the fixture says image/png, which is also the codec's default; the
          # jpeg case is pinned in the protocol suite
          ["predictions", "mimeType"]
        ]
      },
      %{
        name: :seedance_submit,
        codec: LlmCall.Media.Protocol.Seedance.Video,
        kind: :submit,
        payload: LlmCall.Media.Fixtures.SeedanceVideo.submit_response(),
        ignored: []
      },
      %{
        name: :seedance_operation,
        codec: LlmCall.Media.Protocol.Seedance.Video,
        kind: :operation,
        payload: LlmCall.Media.Fixtures.SeedanceVideo.succeeded_response(),
        ignored: []
      },
      %{
        name: :minimax_operation,
        codec: LlmCall.Media.Protocol.MiniMax.Video,
        kind: :operation,
        payload: LlmCall.Media.Fixtures.MiniMaxVideo.success_response(),
        ignored: [
          # an ok base_resp is the provider's success envelope
          ["base_resp"],
          ["base_resp", "status_code"],
          ["base_resp", "status_msg"]
        ]
      }
    ]
  end

  defp decode(codec, payload, :response), do: codec.decode_response(payload, %Config{})
  defp decode(codec, payload, :submit), do: codec.decode_submit(payload, %Config{})
  defp decode(codec, payload, :operation), do: codec.decode_operation(payload, %Config{})

  defp project({:ok, struct}), do: {:ok, Map.put(struct, :raw, nil)}
  defp project(other), do: other

  defp paths(value), do: do_paths(value, [])

  defp do_paths(map, prefix) when is_map(map) and not is_struct(map) do
    Enum.flat_map(map, fn {key, child} -> [prefix ++ [key] | do_paths(child, prefix ++ [key])] end)
  end

  defp do_paths(list, prefix) when is_list(list), do: Enum.flat_map(list, &do_paths(&1, prefix))
  defp do_paths(_value, _prefix), do: []

  defp delete_at(value, [key]) when is_map(value), do: Map.delete(value, key)

  defp delete_at(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, child} -> Map.put(value, key, delete_at(child, rest))
      :error -> value
    end
  end

  defp delete_at(value, path) when is_list(value),
    do: Enum.map(value, &delete_at(&1, path))

  defp classify(codec, payload, kind, path, baseline) do
    mutated = delete_at(payload, path)

    result =
      try do
        decode(codec, mutated, kind)
      rescue
        error -> {:raised, error.__struct__}
      end

    case result do
      {:ok, _} = decoded -> if project(decoded) == baseline, do: :ignored, else: :mapped
      {:error, _} -> :mapped
      {:raised, module} -> {:raised, module}
    end
  end

  test "every provider field is mapped, or ignored for a documented reason" do
    for %{name: name, codec: codec, kind: kind, payload: payload, ignored: allowed} <- cases() do
      baseline = project(decode(codec, payload, kind))

      ignored =
        for path <- paths(payload),
            classify(codec, payload, kind, path, baseline) == :ignored,
            do: path

      assert Enum.sort(ignored) == Enum.sort(allowed),
             """
             #{name}: provider fields that do not reach the canonical struct changed.

             not mapped and not allowed: #{inspect(ignored -- allowed)}
             allowed but now mapped:     #{inspect(allowed -- ignored)}

             Either map the field, or add it to the case's ignored list with a reason.
             """
    end
  end

  test "deleting any single provider field never raises" do
    for %{name: name, codec: codec, kind: kind, payload: payload} <- cases() do
      baseline = project(decode(codec, payload, kind))

      for path <- paths(payload) do
        refute match?({:raised, _}, classify(codec, payload, kind, path, baseline)),
               "#{name}: deleting #{inspect(path)} raised; a codec must be nil-safe"
      end
    end
  end

  test "a missing field is nil or :unknown, never a fabricated value" do
    openai = LlmCall.Protocol.OpenAI.Chat
    payload = LlmCall.Fixtures.OpenAIChat.text_response()
    choice = hd(payload["choices"])

    for {field, key, expected} <- [
          {"id", :id, nil},
          {"model", :model, nil},
          {"usage", :usage, nil}
        ] do
      assert {:ok, response} = openai.decode_response(Map.delete(payload, field), %Config{})
      assert Map.fetch!(response, key) == expected
    end

    missing_stop = %{payload | "choices" => [Map.delete(choice, "finish_reason")]}
    assert {:ok, response} = openai.decode_response(missing_stop, %Config{})
    assert response.stop_reason == :unknown

    zero_usage = %{
      payload
      | "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
    }

    assert {:ok, response} = openai.decode_response(zero_usage, %Config{})
    assert response.usage.input_tokens == 0
    assert response.usage.output_tokens == 0

    anthropic = LlmCall.Protocol.Anthropic.Messages
    apayload = LlmCall.Fixtures.AnthropicMessages.text_response()

    for {field, key, expected} <- [
          {"id", :id, nil},
          {"usage", :usage, nil},
          {"stop_reason", :stop_reason, :unknown}
        ] do
      assert {:ok, response} = anthropic.decode_response(Map.delete(apayload, field), %Config{})
      assert Map.fetch!(response, key) == expected
    end

    gemini = LlmCall.Protocol.Gemini.GenerateContent
    gpayload = LlmCall.Fixtures.GeminiGenerateContent.text_response()

    for {field, key, expected} <- [{"responseId", :id, nil}, {"usageMetadata", :usage, nil}] do
      assert {:ok, response} = gemini.decode_response(Map.delete(gpayload, field), %Config{})
      assert Map.fetch!(response, key) == expected
    end
  end

  test "a malformed error envelope is an invalid_response, not a fabricated provider error" do
    for codec <- [
          LlmCall.Protocol.OpenAI.Chat,
          LlmCall.Protocol.Anthropic.Messages,
          LlmCall.Protocol.Gemini.GenerateContent
        ] do
      assert %LlmCall.Error{kind: :invalid_response} =
               codec.decode_error(%{"error" => %{"code" => "x"}}, %Config{})
    end
  end
end
