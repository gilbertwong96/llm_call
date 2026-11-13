# Contributing

## Which behaviour to implement

- A completion endpoint (messages, system prompt, tools) → `LlmCall.Codec`.
- A dedicated media endpoint (image/video generation, possibly long-running) →
  `LlmCall.Media.Codec`.

Both are described in [`docs/design.md`](docs/design.md) (§10, §23.5).

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

1. Implement every required callback; implement `init_stream/2`,
   `decode_stream_event/3`, `finish_stream/2` only when the protocol streams.
2. Return `Codec.Info` with the correct `ir_version` and wire `version`.
3. **Validate before encoding.** `encode_*` returns
   `{:error, %LlmCall.Error{kind: :validation}}` for anything the protocol cannot
   express. Never drop a canonical field silently.
4. **Declare capabilities that match validation.** A `size` you declare must be
   accepted; a knob you reject must be absent from the declaration. The **media**
   conformance suite checks both directions; the chat suite does not yet.
5. **Use `LlmCall.Protocol.Helpers`** for error formatting, `maybe_put`,
   reserved-key checks, and the `capture_raw` policy, so the suite can assert
   behaviour consistently.
6. **Keep fixtures honest.** Elixir maps, no JSON strings, no network. Copy the
   provider's documented response shape; do not invent one.
7. **Run the conformance suite** in your own tests:

   ```elixir
   LlmCall.Codec.Conformance.assert_info(MyCodec)
   LlmCall.Codec.Conformance.assert_path(MyCodec, request, "/v1/my-endpoint")
   LlmCall.Codec.Conformance.assert_capture_raw(MyCodec, response_fixture)
   LlmCall.Codec.Conformance.assert_stream_state_ownership(MyCodec, OtherCodec, request)
   ```

   or, for media, `LlmCall.MediaConformance` (`assert_info/1`,
   `assert_capabilities/3`, `assert_capability_consistency/3`,
   `assert_submit_path/3`, `assert_capture_raw/2`, `assert_operation/1`,
   `assert_sync_rejects_operation/1` — see the module docs).

   What the suites do not check yet: response/error decoding, event order,
   tool-call assembly, usage mapping, and chat-side capability consistency. Cover
   those with your own fixtures.

## Tests

Run the suite you touched:

```bash
mix test
```

The vendored media adapters run the media conformance suite in the same run.

Formatting and warnings are part of the bar:

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
```

## Documentation

Every module has a moduledoc — no `@moduledoc false`, including fixtures and test
fakes. A test enforces this.
