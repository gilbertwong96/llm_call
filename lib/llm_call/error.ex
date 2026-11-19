defmodule LlmCall.Error do
  @moduledoc """
  A codec error.

  `retryable?` is a hint derived from the provider's error code, not a retry
  policy. `kind` says who produced the error: a codec produces `:validation`,
  `:invalid_response` or `:provider`; the client adds `:transport` for a failure
  that never reached a provider.

  `retry_after_ms` is the parsed `Retry-After` header, when the transport saw
  one; it is a hint, not a retry policy.

  `code` is the provider's machine-readable code as a string (OpenAI's `code`,
  Anthropic's error type, Google's status such as `"RESOURCE_EXHAUSTED"`,
  MiniMax's numeric code stringified). `status` is the HTTP status, and **only the
  client sets it**: a codec never sees the response status, so it always leaves
  it `nil`.

  `reason` is the structured counterpart of a `:transport` message, and only the
  client sets it: `:unknown_pool` when the configured Finch pool is not running,
  `:exception` when the transport raised, and otherwise the transport's own
  reason (`:econnrefused`, `:timeout`, `:closed`, `:nxdomain`,
  `{:tls_alert, ...}`). Match on it instead of the message; a codec leaves it
  `nil`, and so does any failure that has a `status`.
  """

  @typedoc """
  A structured transport reason, or `nil` when the failure has none.

  See the module documentation for the values the client produces.
  """
  @type reason :: :unknown_pool | :exception | atom() | tuple() | nil

  @type t :: %__MODULE__{
          kind: :validation | :invalid_response | :provider | :transport,
          message: String.t(),
          code: String.t() | nil,
          status: non_neg_integer() | nil,
          reason: reason(),
          retryable?: boolean(),
          retry_after_ms: non_neg_integer() | nil,
          raw: map() | nil
        }

  defstruct kind: nil,
            message: nil,
            code: nil,
            status: nil,
            reason: nil,
            retryable?: false,
            retry_after_ms: nil,
            raw: nil
end
