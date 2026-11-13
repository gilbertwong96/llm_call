# llm_call_media

Wire-protocol adapters for media generation, for
[`llm_call`](../..). Core keeps the canonical IR (`MediaRequest`,
`MediaResponse`, `Operation`, `Content.Video`) and the `LlmCall.MediaCodec`
behaviour; this package implements specific providers.

```elixir
def deps do
  [
    {:llm_call, path: "../llm_call"},
    {:llm_call_media, path: "../llm_call/packages/llm_call_media"}
  ]
end
```

## Adapters

| Adapter | Modality | Wire version | Flow |
| --- | --- | --- | --- |
| `LlmCallMedia.Protocol.OpenAI.Images` | image | — | `POST /v1/images/generations` (sync) |
| `LlmCallMedia.Protocol.Gemini.Predict` | image | `v1beta` | `POST /v1beta/models/{model}:predict` (Imagen) |
| `LlmCallMedia.Protocol.Seedance.Video` | video | `v3` | submit -> poll the task -> `content.video_url` |
| `LlmCallMedia.Protocol.MiniMax.Video` | video | `v1` | submit -> poll -> `/v1/files/retrieve` -> `file.download_url` |

Canonical fields each adapter refuses rather than drops:

| Adapter | Rejected as validation errors |
| --- | --- |
| OpenAI Images | `references`, `aspect_ratio`, `duration_s`, `negative_prompt`, `seed`, `n` > 10, unknown `size` |
| Gemini Imagen | `size`, `duration_s`, `seed`, `references` |
| Seedance | `size`, `n`, `negative_prompt`; more than two references; `duration_s` outside 2–30 |
| MiniMax | `size`, `aspect_ratio`, `seed`, `negative_prompt`; more than one reference |

### OpenAI Images

`dall-e-*` models get `response_format: "b64_json"` so assets do not expire;
`gpt-image-1` rejects that key and always returns base64, so it is omitted.
`provider_options.openai` reaches `user`, `output_format`, and other native
knobs. `references` are rejected: edits need a multipart upload, which the
transport owns.

### Gemini Imagen (`predict`)

`instances: [{prompt}]` plus `parameters: {sampleCount, aspectRatio,
negativePrompt}`. Native knobs such as `personGeneration` and `safetySetting`
merge through `provider_options.gemini.parameters`. A prediction with
`raiFilteredReason` and no bytes is skipped while another prediction has bytes,
and is a provider error when none do. `model` must be a bare id (no `/` or `:`),
because it is interpolated into the path.

### Seedance (BytePlus ModelArk)

`POST /api/v3/contents/generations/tasks` with `content` parts: the prompt as
`{type: "text"}`, references as `{type: "image_url", role: ...}`. One reference is
`first_frame`; two are `first_frame` and `last_frame` — ModelArk requires the
roles to tell the pair apart. `ratio`, `duration`, and `seed` are top-level.
`resolution`, `watermark`, `generate_audio`, `camera_fixed`, and `service_tier`
go through `provider_options.seedance`. `durations_s` declares the union across
Seedance models (2–30 s); a model-specific limit is a provider error.

### MiniMax Hailuo (`v1`)

Three calls, expressed as one `Operation`: `POST /v1/video_generation` ->
`task_id`; `GET /v1/query/video_generation?task_id=`; on `Success` the query
returns only a `file_id`, so the operation stays `:in_progress` with `next` =
`GET /v1/files/retrieve?file_id=`, whose `file.download_url` completes the job.
MiniMax reports errors as HTTP 200 with a non-zero `base_resp.status_code`; those
are `:provider` errors. `resolution`, `prompt_optimizer`, `fast_pretreatment`,
`callback_url`, and `extra` go through `provider_options.minimax`.

## Conformance

```bash
mix test
```

The suite runs `LlmCall.MediaConformance` over every adapter here — the same
suite core ships and runs over its own media codec fakes.
