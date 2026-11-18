# Contributing

## Which behaviour to implement

- A completion endpoint (messages, system prompt, tools) →
  `use LlmCall.Protocol.Adapter` (`LlmCall.Codec`).
- A dedicated media endpoint (image/video generation, possibly long-running) →
  `use LlmCall.Media.Adapter` (`LlmCall.Media.Codec`).

Both macros inject the behaviour, the canonical aliases, `@codec`, and the shared
validation entry point; see [`docs/design.md`](docs/design.md) (§10, §23.5).

## Where an adapter belongs

Three questions, in order:

1. **Does it need a canonical concept the IR lacks?** Then it is a design
   discussion in core first; the adapter waits for the IR. Do not smuggle a new
   concept through `provider_options`.
2. **Is it the first implementation of a dialect family** — an envelope shape
   other providers copy? Then it is a candidate for a core *reference adapter*.
   Adding one requires the same justification as adding an IR field: it teaches
   the IR something the current set cannot express.
3. **Otherwise it is vendored here or lives outside.** Vendored adapters go under
   `LlmCall.Media.Protocol.*` (media) and are listed in `LlmCall.Media`; anything
   else is your own module or a third-party package.

Reference adapters are OpenAI Chat, Anthropic Messages, and Gemini
GenerateContent. Vendored media adapters are OpenAI Images, Gemini Imagen,
Seedance, and MiniMax. Everything else — OpenAI Responses, Bedrock, Cohere,
Ollama, Mistral, Sora, Veo — is written outside this repository.

## Namespace rules

- **Vendored adapters** live under `LlmCall.Media.Protocol.*` and are documented
  as vendored: they ship with the library but are not part of the stable API
  surface, because a provider API can change independently of the IR.
- **Out-of-tree adapters** use their own top-level namespace; never define
  `LlmCall.Protocol.*` or `LlmCall.Media.Protocol.*`, which core owns.
- **No canonical struct changes** from an adapter. If the IR is wrong, that is a
  core discussion.

## The quality bar

Every adapter must:

1. Start from the adapter macro (`use LlmCall.Protocol.Adapter, codec: ...`
   with `@path`/`@headers`, or `use LlmCall.Media.Adapter, ...` with a
   modality), then implement every callback it does not inject. Implement
   `init_stream/2`, `decode_stream_event/3`, `finish_stream/2` only when the
   protocol streams.
2. Return `Codec.Info` with the correct `ir_version` and wire `version`.
3. **Validate before encoding.** `encode_*` returns
   `{:error, %LlmCall.Error{kind: :validation}}` for anything the protocol cannot
   express. Never drop a canonical field silently.
4. **Declare capabilities that match validation.** A `size` you declare must be
   accepted; a knob you reject must be absent from the declaration. For media, a
   modality you declare must be accepted, `max_n: :unsupported` must reject every
   `n`, and `max_references` must accept exactly that many references. Both
   conformance suites check these in both directions.
5. **Use `LlmCall.Protocol.Helpers`** for error formatting, `maybe_put`,
   reserved-key checks, and the `capture_raw` policy, so the suite can assert
   behaviour consistently. Declare the namespaces you read (`@namespaces`, or
   `namespaces:` on `use LlmCall.Media.Adapter`) and validate them with
   `Helpers.validate_option_map/4`: an unknown namespace is a validation error,
   because a silently ignored `provider_options` key is a silent drop.
6. **Keep fixtures honest.** Elixir maps, no JSON strings, no network. Copy the
   provider's documented response shape; do not invent one.
7. **Run the conformance suite** in your own tests:

   ```elixir
   LlmCall.Codec.Conformance.assert_info(MyCodec)
   LlmCall.Codec.Conformance.assert_capabilities(MyCodec, stream_request, config)
   LlmCall.Codec.Conformance.assert_path(MyCodec, request, "/v1/my-endpoint")
   LlmCall.Codec.Conformance.assert_stream_request(MyCodec, request)
   LlmCall.Codec.Conformance.assert_reserved_options(MyCodec, request, config, [
     %{my_codec: %{"model" => "evil"}}
   ])
   LlmCall.Codec.Conformance.assert_decode_response(MyCodec, response_fixture)
   LlmCall.Codec.Conformance.assert_invalid_response(MyCodec, %{"unexpected" => true})
   LlmCall.Codec.Conformance.assert_decode_error(MyCodec, error_fixture, code: "rate_limit", retryable?: true)
   LlmCall.Codec.Conformance.assert_stream(MyCodec, stream_request, chunks)
   LlmCall.Codec.Conformance.assert_stream_capture_raw(MyCodec, stream_request, chunks)
   LlmCall.Codec.Conformance.assert_tool_call_assembly(MyCodec, stream_request, tool_chunks, 1)
   LlmCall.Codec.Conformance.assert_capability_consistency(MyCodec, request, config)
   LlmCall.Codec.Conformance.assert_capture_raw(MyCodec, response_fixture)
   LlmCall.Codec.Conformance.assert_stream_roundtrip(MyCodec, stream_request)
   LlmCall.Codec.Conformance.assert_stream_state_ownership(MyCodec, OtherCodec, request)
   LlmCall.Codec.Conformance.assert_rejects(MyCodec, invalid_request, %LlmCall.Config{})
   ```

   or, for media, `LlmCall.MediaConformance` (`assert_info/1`,
   `assert_capabilities/3`, `assert_capability_consistency/3`,
   `assert_submit_path/3`, `assert_capture_raw/2`, `assert_operation/1`,
   `assert_operation_capture_raw/3`, `assert_sync_rejects_operation/1` — see the
   module docs).

   The suites check the IR boundary (canonical parts, stop reasons, usage
   shapes), typed invalid-response and provider-error decoding, stream event
   shape and order, that a streaming request actually asks the provider to
   stream, tool-call assembly through `LlmCall.StreamAssembler`, `capture_raw`
   on responses and operations, and capability declarations agreeing with
   validation in both directions. What they cannot check is usage
   *mapping* — which provider field lands in which counter — so pin that with
   your own fixture assertions.

## Tests

Run the full quality gate before finishing:

```bash
mix ci
```

It compiles with warnings as errors, checks formatting, runs the suite,
`credo --strict`, Dialyzer, SpecLint (with warnings as errors), ExDNA at a zero
clone budget, and the Reach architecture policy. The vendored media adapters run
the media conformance suite in the same `mix test`.

`mix ci` runs ExDNA with a zero clone budget (see `mix.exs`): the protocol
adapters are deliberately parallel, but any logic clone fails the build, so a
shared rule belongs in `LlmCall.Protocol.Helpers`.

## Publishing

Before the first `mix hex.publish`:

1. Confirm `@source_url` in `mix.exs`. It is an assumption until the repository
   exists, and Hex freezes the links and source URL for a published version.
2. `mix ci` is green on both supported toolchains (Elixir 1.18/OTP 27 and the
   current toolchain).
3. `mix hex.build` shows the expected package name, license, and file list.

The zero clone budget in `mix.exs` applies to published versions too: a new clone
fails the gate, so shared logic belongs in `LlmCall.Protocol.Helpers`.

## Documentation

Every module under `lib/` and `test/support/` has a moduledoc — no
`@moduledoc false`. A test enforces this.
