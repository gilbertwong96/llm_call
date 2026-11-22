defmodule LlmCall.WritePathAuditTest do
  @moduledoc """
  Enumerates every canonical field's write path into an encoded body and asserts it
  is protected.

  The failure this pins is not "a codec forgot to validate once"; it is "the same
  canonical value can be written from several sources and only some of them are
  guarded". A maximal request produces the body; every top-level key in it is
  canonical-derived, so each must be rejectable:

    * as a `provider_options` entry in `Config.default_provider_options`;
    * as a request-level entry, if it is part of the envelope;
    * as a `Reasoning.provider_options` entry, where the codec merges reasoning
      options at the body root (OpenAI Chat);
    * as a `ToolSpec.provider_options` entry, for the tool object's own keys;
    * as a nested entry, for a native object the codec merges into
      (`generationConfig`, `thinkingConfig`, `stream_options`).

  Fields a protocol genuinely cannot carry are listed in `docs/design.md`
  (§"Fields a protocol cannot carry") and pinned separately; this test only
  guards the keys that *are* written.
  """

  use ExUnit.Case, async: true

  alias LlmCall.{Config, Content, Error, Message, Reasoning, Request, ToolSpec}

  defp message, do: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]

  defp tools(strict? \\ false) do
    base = %{name: "f", description: "d", parameters: %{"type" => "object"}}
    [struct(ToolSpec, if(strict?, do: Map.put(base, :strict, true), else: base))]
  end

  defp gemini_tools do
    [%ToolSpec{name: "f", description: "d", parameters: %{"type" => "OBJECT"}}]
  end

  defp codecs do
    [
      %{
        name: :openai_chat,
        codec: LlmCall.Dialect.OpenAI.Chat,
        namespace: :openai,
        request: %Request{
          model: "gpt-4o",
          system: "sys",
          messages: message(),
          tools: tools(true),
          tool_choice: {:tool, "f"},
          output: {:json_schema, "s", %{"type" => "object"}, true},
          reasoning: %Reasoning{effort: :high},
          params: %{temperature: 0.2, top_p: 0.9, max_tokens: 64, stop: ["X"], seed: 1},
          stream: true
        },
        envelope: ~w(model messages tools tool_choice response_format reasoning_effort stream),
        parameters: ~w(temperature top_p max_tokens stop seed),
        tool_keys: ~w(name description parameters strict),
        tool_native: "x-native",
        reasoning_keys: :body_root,
        reasoning_base: %Reasoning{effort: :high}
      },
      %{
        name: :openai_responses,
        codec: LlmCall.Dialect.OpenAI.Responses,
        namespace: :openai,
        request: %Request{
          model: "gpt-4.1",
          system: "sys",
          messages: message(),
          tools: tools(true),
          tool_choice: {:tool, "f"},
          output: {:json_schema, "s", %{"type" => "object"}, true},
          reasoning: %Reasoning{effort: :high, summary: :auto},
          params: %{temperature: 0.2, top_p: 0.9, max_tokens: 64},
          stream: true
        },
        envelope: ~w(model input instructions tools tool_choice text reasoning stream),
        parameters: ~w(max_output_tokens temperature top_p),
        tool_keys: ~w(name description parameters strict),
        tool_native: "x-native",
        reasoning_keys: ~w(effort summary),
        reasoning_base: %Reasoning{effort: :high},
        reasoning_native: %{"x-native" => true}
      },
      %{
        name: :anthropic_messages,
        codec: LlmCall.Dialect.Anthropic.Messages,
        namespace: :anthropic,
        request: %Request{
          model: "claude",
          system: "sys",
          messages: message(),
          tools: tools(),
          tool_choice: {:tool, "f"},
          reasoning: %Reasoning{budget_tokens: 1024},
          params: %{max_tokens: 2048, temperature: 0.2, top_p: 0.9, top_k: 5, stop: ["X"]},
          stream: true
        },
        envelope: ~w(model messages system tools thinking stream),
        parameters: ~w(max_tokens temperature top_p top_k stop_sequences),
        tool_keys: ~w(name description input_schema),
        tool_native: "cache_control",
        reasoning_keys: ~w(type budget_tokens),
        reasoning_base: %Reasoning{budget_tokens: 1024},
        reasoning_native: %{"display" => "omitted"}
      },
      %{
        name: :openai_images,
        kind: :media,
        codec: LlmCall.Media.Dialect.OpenAI.Images,
        namespace: :openai,
        request: %LlmCall.Media.Request{
          modality: :image,
          model: "dall-e-3",
          prompt: "a cat",
          params: %{n: 1, size: "1024x1024"}
        },
        envelope: ~w(model prompt n size),
        overridable: ~w(response_format)
      },
      %{
        name: :gemini_predict,
        kind: :media,
        codec: LlmCall.Media.Dialect.Gemini.Predict,
        namespace: :gemini,
        request: %LlmCall.Media.Request{
          modality: :image,
          model: "imagen-3.0-generate-002",
          prompt: "a cat",
          params: %{n: 1, aspect_ratio: "1:1"}
        },
        envelope: ~w(model prompt instances),
        overridable: ~w(parameters)
      },
      %{
        name: :seedance_video,
        kind: :media,
        codec: LlmCall.Media.Dialect.Seedance.Video,
        namespace: :seedance,
        request: %LlmCall.Media.Request{
          modality: :video,
          model: "seedance-1-0-pro-250528",
          prompt: "a cat",
          params: %{aspect_ratio: "16:9", duration_s: 5, seed: 1}
        },
        envelope: ~w(model content ratio duration seed)
      },
      %{
        name: :minimax_video,
        kind: :media,
        codec: LlmCall.Media.Dialect.MiniMax.Video,
        namespace: :minimax,
        request: %LlmCall.Media.Request{
          modality: :video,
          model: "MiniMax-Hailuo-2.3",
          prompt: "a cat",
          params: %{duration_s: 6}
        },
        envelope: ~w(model prompt duration first_frame_image)
      },
      %{
        name: :gemini_generate_content,
        codec: LlmCall.Dialect.Gemini.GenerateContent,
        namespace: :gemini,
        request: %Request{
          model: "gemini-2.5-pro",
          system: "sys",
          messages: message(),
          tools: gemini_tools(),
          tool_choice: {:allowed, ["f"]},
          output: {:json_schema, "s", %{"type" => "OBJECT"}, nil},
          reasoning: %Reasoning{effort: :high},
          params: %{temperature: 0.2, top_p: 0.9, top_k: 5, max_tokens: 64},
          stream: true
        },
        envelope: ~w(contents systeminstruction tools toolconfig),
        parameters: [],
        tool_keys: ~w(name description parameters),
        tool_native: "behavior",
        reasoning_keys: ~w(thinkingbudget thinkinglevel),
        reasoning_base: %Reasoning{effort: :high},
        reasoning_native: %{"includeThoughts" => true},
        nested: %{
          "generationConfig" => ~w(maxoutputtokens responsemimetype responseschema temperature
                                   thinkingconfig)
        }
      }
    ]
  end

  defp codec_config(name), do: Enum.find(codecs(), &(&1.name == name))

  defp encode!(codec, request, config \\ %Config{})

  defp encode!(codec, %LlmCall.Media.Request{} = request, config) do
    assert {:ok, encoded} = codec.encode_submit(request, config)
    encoded
  end

  defp encode!(codec, %Request{} = request, config) do
    assert {:ok, encoded} = codec.encode_request(request, config)
    encoded
  end

  defp validation_error(codec, request, config \\ %Config{}) do
    assert {:error, %Error{kind: :validation, message: message}} =
             codec.validate_request(request, config)

    message
  end

  test "every emitted top-level key is rejected as a Config default" do
    for entry <- codecs() do
      %{name: name, codec: codec, namespace: namespace, request: request} = entry
      body = encode!(codec, request).body
      keys = Map.keys(body) -- Map.get(entry, :overridable, [])

      assert keys != [], "#{name}: the maximal request emitted no auditable body keys"

      for key <- keys do
        message =
          validation_error(codec, %{request | provider_options: %{}}, %Config{
            default_provider_options: %{namespace => %{key => true}}
          })

        assert message =~ "canonical field" or message =~ "must be a map",
               "#{name}: #{key} emitted from canonical fields but a Config default can " <>
                 "set it: #{message}"
      end
    end
  end

  test "envelope keys are rejected on the request" do
    entries = Enum.filter(codecs(), &(is_list(&1[:envelope]) and &1[:envelope] != []))
    assert entries != [], "no codec declares envelope keys to audit"

    for %{name: name, codec: codec, namespace: namespace, request: request, envelope: keys} <-
          entries do
      for key <- keys do
        message =
          validation_error(codec, %{request | provider_options: %{namespace => %{key => true}}})

        assert message =~ "canonical field",
               "#{name}: request provider_options can set the envelope key #{key}: #{message}"
      end
    end
  end

  test "parameter keys are request-level escape hatches, not silently accepted everywhere" do
    entries = Enum.filter(codecs(), &(is_list(&1[:parameters]) and &1[:parameters] != []))
    assert entries != [], "no codec declares parameter keys to audit"

    for %{name: name, codec: codec, namespace: namespace, request: request, parameters: keys} <-
          entries do
      for key <- keys do
        assert :ok ==
                 codec.validate_request(
                   %{request | provider_options: %{namespace => %{key => true}}},
                   %Config{}
                 ),
               "#{name}: #{key} is documented as a request-level override"
      end
    end
  end

  test "tool options cannot replace the function object" do
    entries = Enum.filter(codecs(), &(is_list(&1[:tool_keys]) and &1[:tool_keys] != []))
    assert entries != [], "no codec declares tool keys to audit"

    for %{name: name, codec: codec, request: request, tool_keys: keys, tool_native: native} <-
          entries do
      for key <- keys do
        spec = %ToolSpec{name: "f", parameters: %{}, provider_options: %{key => true}}

        message = validation_error(codec, %{request | tools: [spec]})

        assert message =~ "canonical field",
               "#{name}: tool provider_options can replace #{key}: #{message}"
      end

      native_spec = %ToolSpec{name: "f", parameters: %{}, provider_options: %{native => true}}

      assert :ok == codec.validate_request(%{request | tools: [native_spec]}, %Config{}),
             "#{name}: tool provider_options must still accept a native key like #{native}"
    end
  end

  test "reasoning options cannot replace the reasoning object" do
    entries = Enum.filter(codecs(), &Map.has_key?(&1, :reasoning_keys))
    assert entries != [], "no codec declares reasoning keys to audit"

    for %{name: name, codec: codec, request: request, reasoning_keys: keys} <- entries do
      keys =
        case keys do
          :body_root -> Map.keys(encode!(codec, request).body)
          list -> list
        end

      base = Map.fetch!(codec_config(name), :reasoning_base)

      for key <- keys do
        reasoning = %{base | provider_options: %{key => true}}
        message = validation_error(codec, %{request | reasoning: reasoning})

        assert message =~ "canonical field" or message =~ key,
               "#{name}: reasoning.provider_options can replace #{key}: #{message}"
      end
    end
  end

  test "reasoning options still accept a native key" do
    entries = Enum.filter(codecs(), &is_map(&1[:reasoning_native]))
    assert entries != [], "no codec declares a native reasoning key to audit"

    for %{name: name, codec: codec, request: request, reasoning_native: native} <- entries do
      base = Map.fetch!(codec_config(name), :reasoning_base)
      reasoning = %{base | provider_options: native}

      assert :ok == codec.validate_request(%{request | reasoning: reasoning}, %Config{}),
             "#{name}: reasoning.provider_options must accept #{inspect(Map.keys(native))}"
    end
  end

  test "a nested native object protects the keys the codec derives" do
    entries = Enum.filter(codecs(), &is_map(&1[:nested]))
    assert entries != [], "no codec declares a nested native object to audit"

    for %{name: name, codec: codec, namespace: namespace, request: request, nested: nested} <-
          entries do
      for {object, keys} <- nested, key <- keys do
        options = %{namespace => %{object => %{key => true}}}

        message = validation_error(codec, %{request | provider_options: options})

        assert message =~ "canonical field",
               "#{name}: provider_options.#{object}.#{key} replaces a canonical field: #{message}"

        defaults = %Config{default_provider_options: options}
        message = validation_error(codec, %{request | provider_options: %{}}, defaults)

        assert message =~ "canonical field",
               "#{name}: a Config default can set #{object}.#{key}: #{message}"
      end
    end
  end

  test "stream_options protects include_usage from every source" do
    codec = LlmCall.Dialect.OpenAI.Chat
    request = %{Enum.find(codecs(), &(&1.name == :openai_chat)).request | stream: true}

    request_message =
      validation_error(codec, %{
        request
        | provider_options: %{openai: %{"stream_options" => %{"include_usage" => false}}}
      })

    assert request_message =~ "canonical field"

    defaults_message =
      validation_error(codec, %{request | provider_options: %{}}, %Config{
        default_provider_options: %{openai: %{"stream_options" => %{"include_usage" => false}}}
      })

    assert defaults_message =~ "canonical field"

    reasoning_message =
      validation_error(codec, %{
        request
        | reasoning: %Reasoning{
            effort: :high,
            provider_options: %{"stream_options" => %{"include_usage" => false}}
          }
      })

    assert reasoning_message =~ "canonical field"

    for source <- [
          %{
            request
            | provider_options: %{openai: %{"stream_options" => %{"include_obfuscation" => true}}}
          },
          %{
            request
            | reasoning: %Reasoning{
                effort: :high,
                provider_options: %{"stream_options" => %{"include_obfuscation" => true}}
              }
          }
        ] do
      assert :ok == codec.validate_request(source, %Config{})
    end

    assert :ok ==
             codec.validate_request(%{request | provider_options: %{}}, %Config{
               default_provider_options: %{
                 openai: %{"stream_options" => %{"include_obfuscation" => true}}
               }
             })
  end
end
