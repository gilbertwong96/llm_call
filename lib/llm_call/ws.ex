defmodule LlmCall.WS do
  @moduledoc """
  The WebSocket transport contract.

  A session at this layer is synchronous: `connect/3` performs the HTTP upgrade
  and returns a connection, `send_frame/2` writes one frame, and `recv/2` blocks
  for one frame. A caller that needs concurrency (a realtime session) runs the
  connection in its own process and owns the socket from `connect/3` onward.

  Only data frames cross the contract. `recv/2` answers pings itself, ignores
  pongs, and reports a peer close as `{:close, code, reason}`.

  The library ships `LlmCall.WS.Mint` as the default implementation.
  """

  @type url :: String.t()

  @type frame :: {:text, binary()} | {:binary, binary()}

  @type received :: frame() | {:close, non_neg_integer(), binary()}

  @type error :: term()

  @type conn :: term()

  @doc """
  Opens a connection to `url` (`ws://` or `wss://`) with the given headers.

  Options are implementation-specific; `LlmCall.WS.Mint` accepts `:timeout`
  (connect and upgrade, default 15 seconds) and `:transport_opts`.
  """
  @callback connect(url(), [{String.t(), String.t()}], keyword()) ::
              {:ok, conn()} | {:error, error()}

  @doc "Writes one data frame."
  @callback send_frame(conn(), frame()) :: {:ok, conn()} | {:error, error()}

  @doc """
  Waits up to `timeout` milliseconds for one data frame or a peer close.
  """
  @callback recv(conn(), timeout()) :: {:ok, received(), conn()} | {:error, error()}

  @doc "Sends a close frame and closes the socket."
  @callback close(conn(), non_neg_integer(), binary()) :: :ok
end
