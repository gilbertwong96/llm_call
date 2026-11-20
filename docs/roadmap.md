# Roadmap

Where the wire layer stands, what it deliberately leaves out, and the order in which
further operation families would arrive. `docs/design.md` is the canonical spec; this
page is the plan, and it changes more often.

## 1. Delivered in 0.1

The implementation order the release followed, kept because it shows how the layers
depend on each other:

1. Canonical structs and types, including reasoning.
2. Codec behaviour, encoded request, error, capabilities.
3. OpenAI Chat codec with request/response/stream fixtures.
4. Anthropic Messages codec.
5. Gemini GenerateContent codec.
6. Generic OpenAI-compatible configuration.
7. `LlmCall.HTTP` on Finch and the default pool.
8. `LlmCall.JSON` as a behaviour, threaded through the codecs and resolved (with
   `http`, `http_opts`, `timeout`) from call option, provider, application
   environment and default.
9. `LlmCall.Client`, `LlmCall.Provider`, and `complete/3`, `execute/2`, `fetch/2`.
10. `LlmCall.SSE`, `LlmCall.Stream` and `stream/3`.
11. The media IR (design §23): `Content.Video`, `Request.modalities`,
    `Capabilities.modalities`, `LlmCall.Media.Request`, `LlmCall.Media.Response`,
    `LlmCall.Operation`, `LlmCall.Media.Capabilities`, the `LlmCall.Media.Codec`
    behaviour, and the public media API.
12. `generate/3` and `poll/3` for the media IR.
13. The conformance suites published from `lib/`, the ban on `@moduledoc false`, and
    the adapter-authoring contract.
14. Provider-hosted tools: the builtin envelope, the `builtin_tools` capability, and
    the codec branches.
15. The media adapters under `LlmCall.Media.Dialect.*`: OpenAI Images, Gemini Imagen
    `predict`, Seedance, MiniMax Hailuo.
16. The OpenAI Responses codec (`POST /v1/responses`) on the HTTP/SSE transport.
17. The `LlmCall.WS` behaviour and `LlmCall.WS.Mint`, and the test servers that
    exercise them.

## 2. Further operation families

0.1 ships two operation families — completion (`LlmCall.Codec`) and media generation
with its long-running operations (`LlmCall.Media.Codec`) — plus the Responses
WebSocket transport. Further families follow the same rule as design §25.3.1: **a new
operation is a new IR plus a codec behaviour**, and never a new field on `Request`.
Adding one is therefore additive and does not disturb the IR contract.

### 2.1 What a family costs

A codec is small; the fixed cost per family is what surrounds it, and it multiplies per
provider:

- the canonical request/response/capabilities structs;
- a codec behaviour, an adapter macro and a conformance suite;
- one adapter, fixture set and wire-fact verification per provider;
- client entry points, documentation and CHANGELOG surface.

The suite cost scales with the family's wire surface, not with its importance. An
embedding suite covers shapes, vector dimensions, usage and errors — no stream, no
operation state machine, no asset hop — so it is a fraction of the media suite.

That cost model is the reason the order below exists: breadth is the wrong thing to buy
first. The library's claim is a verifiable wire contract, not "every model in every
modality"; a full-client library already occupies that ground.

### 2.2 Prerequisite: parameterise the family

Completion and media are currently two hand-written pipelines: two behaviours, two
adapter macros, two conformance skeletons, two client surfaces. Writing a third and
fourth family by hand multiplies that plumbing. Before family #3, one refactor turns
"a family" into a parameterised mechanism — codec behaviour, adapter macro, conformance
skeleton, client entry points — with media as its first instance. That is a
reorganisation, not a feature, and it belongs in a 0.x minor.

### 2.3 Order and verdict

| Operation | Canonical shape | New family | Demand | Plan |
| --- | --- | --- | --- | --- |
| Embeddings | `{model, input, dimensions?}` → vectors + usage | yes, small | highest: a conversation library is almost always paired with a vector store | 0.2, with rerank |
| Rerank | `{model, query, documents, top_n?}` → ordered scores | shares the vector family | medium, narrow vendor set | 0.2 |
| Speech | text in, media bytes out | media-shaped | medium-low | 0.3 |
| Transcription | bytes in, text and segments out; needs the multipart boundary the transport deliberately does not own (design §23.7) | yes | medium | 0.3, once that boundary has a design |
| OCR | image or file in, text out | **no**: `Content.Image` and `Content.File` in a chat request already express it for every multimodal codec | low | documentation; a dedicated endpoint only on demand |
| Evaluation | "answer named questions about this text/JSON" | **no**: it is an upper-layer abstraction built on chat or structured output, not a provider endpoint | low | never in core |

### 2.4 Criteria for adding a family

A family enters the core only when all three hold:

1. its canonical shape is expressible without `provider_options`;
2. at least two providers need it — a single-vendor endpoint belongs in the
   application, not in a protocol library;
3. someone carries the per-provider adapter and verification cost, and the conformance
   suite for the family is written in the same change.
