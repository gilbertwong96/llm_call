defmodule LlmDialect.StreamDeltaAuditTest do
  @moduledoc """
  Enumerates every provider field in a streaming chunk and proves it reaches a
  canonical event, or is listed as an ignored envelope/echo field.

  Same method as `LlmDialect.DecodePathAuditTest`, applied to the streaming path:
  delete one meaningful provider leaf from one chunk (`nil`, `""`, `%{}`, and `[]`
  leaves are skipped, since removing them can never change an event), decode the
  whole stream again, and compare `{type, delta, index}` for every event.

  The deltas are the point: `StreamDelta.Text.text`, `.Thinking.text`/`.signature`,
  `.ToolCall.id`/`.name`/`.arguments`/`.index`, `.MessageDelta.stop_reason`/`.usage`,
  and `StreamEvent.index` each have to be filled from somewhere. A field this test
  reports as ignored is either an echo (`choices[].index`, `candidates[].index`), a
  discriminator (`tool_calls[].type`, `content_block.type`), stream metadata the IR
  does not model (`id`, `model`, `responseId`, `modelVersion`), or a bug.

  Deleting any single field must not raise: a provider may omit any optional key.
  """

  use ExUnit.Case, async: true

  alias LlmDialect.{Config, Content, Message, Request}

  defp cases do
    [
      %{
        name: :openai_text,
        codec: LlmDialect.Protocol.OpenAI.Chat,
        model: "gpt-4o",
        chunks: LlmDialect.Fixtures.OpenAIChat.text_chunks(),
        ignored: [
          # stream-level metadata: the IR has no response id/model on an event
          {0, ["id"]},
          {0, ["model"]},
          {1, ["id"]},
          {1, ["model"]},
          # choice index echo: events are keyed by the choice they came from
          {2, ["choices", "index"]}
        ]
      },
      %{
        name: :openai_tool_calls,
        codec: LlmDialect.Protocol.OpenAI.Chat,
        model: "gpt-4o",
        chunks: LlmDialect.Fixtures.OpenAIChat.tool_call_chunks(),
        ignored: [
          {0, ["id"]},
          {0, ["model"]},
          # the fixture's tool-call index equals the choice index, so deleting it
          # falls back to the same value; a differing case is pinned in the
          # protocol suite
          {1, ["choices", "delta", "tool_calls", "index"]},
          {1, ["choices", "delta", "tool_calls", "type"]},
          {1, ["choices", "index"]},
          {2, ["choices", "delta", "tool_calls", "index"]},
          {2, ["choices", "index"]},
          {3, ["choices", "index"]}
        ]
      },
      %{
        name: :openai_usage,
        codec: LlmDialect.Protocol.OpenAI.Chat,
        model: "gpt-4o",
        chunks: LlmDialect.Fixtures.OpenAIChat.usage_split_chunks(),
        ignored: [{0, ["choices", "index"]}]
      },
      %{
        name: :anthropic_text,
        codec: LlmDialect.Protocol.Anthropic.Messages,
        model: "claude",
        chunks: LlmDialect.Fixtures.AnthropicMessages.text_stream(),
        ignored: [
          {0, ["message", "id"]},
          {0, ["message", "model"]},
          # the later message_delta overwrites output_tokens; input_tokens is
          # load-bearing and is asserted in the protocol suite
          {0, ["message", "usage", "output_tokens"]},
          # block envelope; the deltas carry the text
          {1, ["content_block"]},
          {1, ["content_block", "type"]}
        ]
      },
      %{
        name: :anthropic_tool_calls,
        codec: LlmDialect.Protocol.Anthropic.Messages,
        model: "claude",
        chunks: LlmDialect.Fixtures.AnthropicMessages.tool_stream(),
        ignored: [
          {0, ["message", "id"]},
          {0, ["message", "model"]},
          {0, ["message", "usage", "output_tokens"]}
        ]
      },
      %{
        name: :anthropic_thinking,
        codec: LlmDialect.Protocol.Anthropic.Messages,
        model: "claude",
        chunks: LlmDialect.Fixtures.AnthropicMessages.thinking_stream(),
        ignored: [
          # this fixture has no message_delta, so the merged usage never surfaces;
          # the protocol suite's "a later usage delta keeps fields it omits" case
          # pins the merge
          {0, ["message"]},
          {0, ["message", "id"]},
          {0, ["message", "model"]},
          {0, ["message", "usage"]},
          {0, ["message", "usage", "input_tokens"]},
          {0, ["message", "usage", "output_tokens"]},
          {1, ["content_block"]},
          {1, ["content_block", "type"]}
        ]
      },
      %{
        name: :gemini_text,
        codec: LlmDialect.Protocol.Gemini.GenerateContent,
        model: "gemini-2.5-pro",
        chunks: LlmDialect.Fixtures.GeminiGenerateContent.text_chunks(),
        ignored: [
          {0, ["candidates", "content", "role"]},
          {0, ["candidates", "index"]},
          {1, ["candidates", "content", "role"]},
          {1, ["candidates", "index"]},
          {2, ["candidates", "index"]},
          {2, ["modelVersion"]},
          {2, ["responseId"]}
        ]
      },
      %{
        name: :gemini_tool_calls,
        codec: LlmDialect.Protocol.Gemini.GenerateContent,
        model: "gemini-2.5-pro",
        chunks: LlmDialect.Fixtures.GeminiGenerateContent.tool_chunks(),
        ignored: [{0, ["candidates", "content", "role"]}, {0, ["candidates", "index"]}]
      },
      %{
        name: :gemini_thought,
        codec: LlmDialect.Protocol.Gemini.GenerateContent,
        model: "gemini-2.5-pro",
        chunks: [LlmDialect.Fixtures.GeminiGenerateContent.thought_chunk()],
        ignored: [{0, ["candidates", "content", "role"]}, {0, ["candidates", "index"]}]
      }
    ]
  end

  defp run(codec, model, chunks) do
    request = %Request{
      model: model,
      stream: true,
      params: %{max_tokens: 8},
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }

    with {:ok, state} <- codec.init_stream(request, %Config{}) do
      {events, state} = decode_chunks(codec, chunks, state)
      finish(codec, events, state)
    end
  end

  defp decode_chunks(codec, chunks, state) do
    Enum.reduce_while(chunks, {[], state}, fn chunk, {events, state} ->
      case codec.decode_stream_event(chunk, %Config{}, state) do
        {:ok, new_events, next} -> {:cont, {events ++ new_events, next}}
        {:done, next} -> {:halt, {events, next}}
        {:error, _error} -> {:halt, {events, state}}
      end
    end)
  end

  defp finish(codec, events, state) do
    case codec.finish_stream(state, %Config{}) do
      {:ok, tail, _state} -> {:ok, Enum.map(events ++ tail, &{&1.type, &1.delta, &1.index})}
      other -> other
    end
  end

  defp paths(value), do: do_paths(value, [])

  defp do_paths(map, prefix) when is_map(map) and not is_struct(map) do
    Enum.flat_map(map, fn {key, child} ->
      if meaningful?(child), do: [prefix ++ [key] | do_paths(child, prefix ++ [key])], else: []
    end)
  end

  defp do_paths(list, prefix) when is_list(list), do: Enum.flat_map(list, &do_paths(&1, prefix))
  defp do_paths(_value, _prefix), do: []

  defp meaningful?(nil), do: false
  defp meaningful?(value) when is_map(value) and not is_struct(value), do: map_size(value) > 0
  defp meaningful?([]), do: false
  defp meaningful?(""), do: false
  defp meaningful?(_value), do: true

  defp delete_at(value, [key]) when is_map(value), do: Map.delete(value, key)

  defp delete_at(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, child} -> Map.put(value, key, delete_at(child, rest))
      :error -> value
    end
  end

  defp delete_at(value, path) when is_list(value), do: Enum.map(value, &delete_at(&1, path))

  test "every chunk field reaches an event, or is ignored for a documented reason" do
    for %{name: name, codec: codec, model: model, chunks: chunks, ignored: allowed} <- cases() do
      {:ok, baseline} = run(codec, model, chunks)

      ignored =
        for {chunk, index} <- Enum.with_index(chunks),
            path <- paths(chunk),
            mutated = List.replace_at(chunks, index, delete_at(chunk, path)),
            match?({:ok, ^baseline}, run(codec, model, mutated)),
            do: {index, path}

      assert Enum.sort(ignored) == Enum.sort(allowed),
             """
             #{name}: chunk fields that do not reach a canonical event changed.

             not mapped and not allowed: #{inspect(ignored -- allowed)}
             allowed but now mapped:     #{inspect(allowed -- ignored)}

             Either map the field, or add it to the case's ignored list with a reason.
             """
    end
  end

  test "deleting any single chunk field never raises" do
    for %{name: name, codec: codec, model: model, chunks: chunks} <- cases() do
      for {chunk, index} <- Enum.with_index(chunks), path <- paths(chunk) do
        mutated = List.replace_at(chunks, index, delete_at(chunk, path))

        assert {:ok, _events} = run(codec, model, mutated),
               "#{name}: deleting #{inspect(path)} from chunk #{index} raised or errored; " <>
                 "a codec must be nil-safe"
      end
    end
  end

  test "an unmapped provider field becomes a Raw event, not a dropped one" do
    chunk = %{
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"moderation" => %{"flagged" => true}},
          "finish_reason" => nil
        }
      ]
    }

    assert {:ok, events} = run(LlmDialect.Protocol.OpenAI.Chat, "gpt-4o", [chunk])

    assert Enum.any?(events, fn
             {:message_delta, %LlmDialect.StreamDelta.Raw{data: data}, nil} ->
               data == %{"data" => %{"moderation" => %{"flagged" => true}}}

             _event ->
               false
           end)
  end
end
