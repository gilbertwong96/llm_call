defmodule LlmCall.Operation do
  @moduledoc """
  A long-running media generation job.

  `next` is the encoded request the caller's transport executes next, built by the
  codec so the transport needs no knowledge of the protocol's job URL.

  - `next_kind: :poll` decodes the response body with
    `LlmCall.decode_operation/3`.
  - `next_kind: :asset` means the response body is media bytes; the core never
    touches them and the caller stores them using `next_media_type`.

  `status: :completed` is never paired with `next_kind: :poll`: a codec that knows
  the asset needs another request says so in the same result.

  The core never polls, waits, retries, or downloads.
  """

  @type status :: :queued | :in_progress | :completed | :failed

  @type t :: %__MODULE__{
          id: String.t() | nil,
          status: status(),
          progress: 0..100 | nil,
          result: LlmCall.MediaResponse.t() | nil,
          next: LlmCall.EncodedRequest.t() | nil,
          next_kind: :poll | :asset | nil,
          next_media_type: String.t() | nil,
          error: LlmCall.Error.t() | nil,
          raw: map() | nil
        }

  defstruct id: nil,
            status: :queued,
            progress: nil,
            result: nil,
            next: nil,
            next_kind: nil,
            next_media_type: nil,
            error: nil,
            raw: nil
end
