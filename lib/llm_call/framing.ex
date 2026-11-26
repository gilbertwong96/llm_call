defmodule LlmCall.Framing do
  @moduledoc """
  How a streaming body is cut into messages.

  A wire format frames its stream one of two ways: server-sent events, which are
  text terminated by a blank line (`LlmCall.SSE`), or AWS event stream, which is
  length-prefixed binary frames (`LlmCall.EventStream`). A codec names its framing
  through the optional `stream_framing/0` callback; `LlmCall.Stream` drives it, and
  the codec only ever sees a decoded payload.

  The contract is the same for both: a chunk may split a message, so state is
  carried between calls, and end of body has its own call because trailing bytes can
  complete a message or prove the stream was cut short.

  `parse/2` and `flush/1` raise the framing's own exception — `LlmCall.SSE.Error`,
  `LlmCall.EventStream.Error` — which `error/0` names. `LlmCall.Stream` converts
  exactly that exception into an `:invalid_response`; anything else is a bug in the
  framing or the caller and propagates.

  The state is opaque: each framing defines its own struct, and the payload type
  belongs to the framing (`String.t()` for SSE, a
  `LlmCall.EventStream.Message` for event stream).
  """

  @typedoc "A framing's incremental state, opaque to the caller."
  @type state :: term()

  @typedoc "A framing's decoded payload; the codec decides what it means."
  @type payload :: term()

  @doc "A fresh framing state."
  @callback new() :: state()

  @doc "Consumes one body chunk and returns the payloads it completes."
  @callback parse(state(), binary()) :: {[payload()], state()}

  @doc """
  Handles end of body.

  SSE returns a trailing event that arrived without its blank line; event stream
  has nothing to return and raises instead when bytes remain, because a body that
  ends mid-frame lost part of a message.
  """
  @callback flush(state()) :: {[payload()], state()}

  @doc """
  Turns a framed payload into the term the codec's `decode_stream_event/3`
  receives.

  SSE payloads are bare JSON text, so that framing decodes them; event-stream
  payloads arrive inside an envelope whose headers say what they are, so the framed
  message is handed over as it is. Doing this at the framing, rather than in
  `LlmCall.Stream`, is what keeps the stream driver free of protocol knowledge.
  """
  @callback codec_input(payload(), json :: module()) :: {:ok, term()} | {:error, String.t()}

  @doc "The exception this framing raises for a body that cannot be framed."
  @callback error() :: module()
end
