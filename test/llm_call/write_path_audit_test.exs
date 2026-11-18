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

  defp codecs do
    [
      %{
        name: :openai_chat,
        codec: LlmCall.Protocol.OpenAI.Chat,
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
        name: :anthropic_messages,
        codec: LlmCall.Protocol.Anthropic.Messages,
        namespace: :anthropic,
        request: %Request{
          model: "claude",
          system: "sys",
          messages: message(),
          tools: tools(),
          tool_choice: {:tool, "f"},
          reasoning: %Reasoning{budget_tokens: 1024},
          params: %{max_tokens: 64, temperature: 0.2, top_p: 0.9, top_k: 5, stop: ["X"]},
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
        name: :gemini_generate_content,
        codec: LlmCall.Protocol.Gemini.GenerateContent,
        namespace: :gemini,
        request: %Request{
          model: "gemini-2.5-pro",
          system: "sys",
          messages: message(),
          tools: tools(),
          tool_choice: {:allowed, ["f"]},
          output: {:json_schema, "s", %{"type" => "object"}, nil},
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

  defp encode!(codec, request, config \\ %Config{}) do
    assert {:ok, encoded} = codec.encode_request(request, config)
    encoded
  end

  defp validation_error(codec, request, config \\ %Config{}) do
    assert {:error, %Error{kind: :validation, message: message}} =
             codec.validate_request(request, config)

    message
  end

  test "every emitted top-level key is rejected as a Config default" do
    for %{name: name, codec: codec, namespace: namespace, request: request} <- codecs() do
      body = encode!(codec, request).body

      for key <- Map.keys(body) do
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
    for %{name: name, codec: codec, namespace: namespace, request: request, envelope: keys} <-
          codecs() do
      for key <- keys do
        message =
          validation_error(codec, %{request | provider_options: %{namespace => %{key => true}}})

        assert message =~ "canonical field",
               "#{name}: request provider_options can set the envelope key #{key}: #{message}"
      end
    end
  end

  test "parameter keys are request-level escape hatches, not silently accepted everywhere" do
    for %{name: name, codec: codec, namespace: namespace, request: request, parameters: keys} <-
          codecs(),
        keys != [] do
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
    for %{name: name, codec: codec, request: request, tool_keys: keys, tool_native: native} <-
          codecs() do
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
    for %{name: name, codec: codec, request: request, reasoning_keys: keys} <- codecs() do
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
    for %{name: name, codec: codec, request: request, reasoning_native: native} <- codecs(),
        is_map(native) do
      base = Map.fetch!(codec_config(name), :reasoning_base)
      reasoning = %{base | provider_options: native}

      assert :ok == codec.validate_request(%{request | reasoning: reasoning}, %Config{}),
             "#{name}: reasoning.provider_options must accept #{inspect(Map.keys(native))}"
    end
  end

  test "a nested native object protects the keys the codec derives" do
    for %{name: name, codec: codec, namespace: namespace, request: request, nested: nested} <-
          codecs(),
        is_map(nested) do
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
    codec = LlmCall.Protocol.OpenAI.Chat
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
