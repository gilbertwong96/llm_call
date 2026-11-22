defmodule LlmCall.WS.Mint do
  @moduledoc """
  The default WebSocket transport, backed by `Mint.WebSocket`.

  The connection is active and owned by the process that calls `connect/3`:
  Mint delivers socket messages to that process, and `recv/2` (or `feed/2`)
  passes them to `Mint.WebSocket.stream/2`. A caller that moves the connection
  to another process must do so after `connect/3` returns.

  Pings are answered with their payload inside `recv/2` and `feed/2`; pongs are
  ignored. A peer close is returned as `{:close, code, reason}`; closing the
  socket is the caller's decision.

  Options: `:timeout` (connect and upgrade, default 15 seconds),
  `:transport_opts`, `:proxy`, `:proxy_headers`, `:log`. The socket must stay
  active, so `mode: :active` is the only accepted value; anything else is
  `{:error, {:unsupported_mode, mode}}` rather than a connect timeout.
  """

  @behaviour LlmCall.WS

  @default_timeout 15_000

  @impl true
  def connect(url, headers, opts \\ []) do
    with :ok <- validate_mode(opts),
         {:ok, uri, scheme} <- parse_url(url),
         {:ok, conn} <-
           Mint.HTTP.connect(transport_scheme(scheme), uri.host, uri.port, connect_opts(opts)) do
      start_upgrade(conn, scheme, uri, headers, opts)
    end
  end

  # `recv/2` and `feed/2` deliver through active-mode socket messages, so a
  # passive connection can never complete the upgrade; reject it up front
  # instead of waiting for the connect timeout.
  defp validate_mode(opts) do
    case Keyword.get(opts, :mode, :active) do
      :active -> :ok
      other -> {:error, {:unsupported_mode, other}}
    end
  end

  @impl true
  def send_frame(state, {:text, _data} = frame), do: write(state, frame)
  def send_frame(state, {:binary, _data} = frame), do: write(state, frame)

  @impl true
  def recv(state, timeout \\ @default_timeout) do
    do_recv(state, deadline(timeout))
  end

  @impl true
  def close(state, code \\ 1000, reason \\ "") do
    state =
      case write(state, {:close, code, reason}) do
        {:ok, state} -> state
        {:error, _reason} -> state
      end

    Mint.HTTP.close(state.conn)
    :ok
  end

  defp start_upgrade(conn, scheme, uri, headers, opts) do
    headers = ensure_host(headers, uri)

    case Mint.WebSocket.upgrade(scheme, conn, path(uri), headers) do
      {:ok, conn, ref} ->
        await_upgrade(
          %{conn: conn, ref: ref, websocket: nil, pending: []},
          deadline(timeout(opts))
        )

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  defp await_upgrade(state, deadline) do
    case receive_stream(state, deadline) do
      {:ok, state, responses} ->
        status =
          Enum.find_value(responses, fn
            {:status, _, status} -> status
            _ -> nil
          end)

        headers =
          Enum.find_value(responses, fn
            {:headers, _, headers} -> headers
            _ -> nil
          end)

        cond do
          status == 101 and is_list(headers) ->
            upgrade(state, headers)

          is_integer(status) ->
            Mint.HTTP.close(state.conn)
            {:error, {:upgrade_failed, status}}

          true ->
            await_upgrade(state, deadline)
        end

      {:error, reason} ->
        Mint.HTTP.close(state.conn)
        {:error, reason}
    end
  end

  # Dialyzer cannot see Mint.WebSocket.new/4's HTTP/1 success branch through
  # Mint's opaque connection type; the status and protocol are checked here.
  @dialyzer {:nowarn_function, upgrade: 2}
  defp upgrade(state, headers) do
    if Mint.HTTP.protocol(state.conn) == :http1 do
      case Mint.WebSocket.new(state.conn, state.ref, 101, headers) do
        {:ok, conn, websocket} ->
          {:ok, %{state | conn: conn, websocket: websocket}}

        {:error, conn, reason} ->
          Mint.HTTP.close(conn)
          {:error, reason}
      end
    else
      Mint.HTTP.close(state.conn)
      {:error, :unsupported_protocol}
    end
  end

  defp do_recv(state, deadline) do
    case drain(state) do
      {:frame, frame, state} ->
        {:ok, frame, state}

      {:cont, state} ->
        case receive_stream(state, deadline) do
          {:ok, state, responses} -> decode(responses, state, deadline)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(responses, state, deadline) do
    case collect_responses(responses, state) do
      {:ok, [], state} ->
        do_recv(state, deadline)

      {:ok, [frame | rest], state} ->
        {:ok, frame, %{state | pending: rest}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def feed(state, message) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        with {:ok, new_frames, state} <- collect_responses(responses, %{state | conn: conn}),
             {:ok, pending, state} <- drain_pending(state) do
          {:ok, pending ++ new_frames, state}
        end

      {:error, _conn, reason, _responses} ->
        {:error, reason}

      :unknown ->
        drain_pending(state)
    end
  end

  defp drain_pending(%{pending: []} = state), do: {:ok, [], state}

  defp drain_pending(state) do
    collect(state.pending, %{state | pending: []}, [])
  end

  defp collect_responses(responses, state) do
    Enum.reduce_while(responses, {:ok, [], state}, fn
      {:data, _ref, data}, {:ok, frames, state} ->
        case collect_data(data, state) do
          {:ok, new_frames, state} -> {:cont, {:ok, frames ++ new_frames, state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:error, _ref, reason}, _acc ->
        {:halt, {:error, reason}}

      {:done, _ref}, _acc ->
        {:halt, {:error, :closed}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp collect_data(data, state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, decoded} -> collect(decoded, %{state | websocket: websocket}, [])
      {:error, _websocket, reason} -> {:error, reason}
    end
  end

  defp collect([], state, acc), do: {:ok, Enum.reverse(acc), state}

  defp collect([frame | rest], state, acc) do
    case frame do
      {:text, _data} ->
        collect(rest, state, [frame | acc])

      {:binary, _data} ->
        collect(rest, state, [frame | acc])

      {:close, code, reason} ->
        collect(rest, state, [{:close, code, reason} | acc])

      :ping ->
        reply_pong(rest, state, acc, "")

      {:ping, payload} ->
        reply_pong(rest, state, acc, payload)

      pong when pong in [:pong, {:pong, ""}] ->
        collect(rest, state, acc)

      {:error, reason} ->
        {:error, reason}

      _other ->
        collect(rest, state, acc)
    end
  end

  defp drain(%{pending: []} = state), do: {:cont, state}

  defp drain(state) do
    case collect(state.pending, state, []) do
      {:ok, [], state} -> {:cont, %{state | pending: []}}
      {:ok, [frame | rest], state} -> {:frame, frame, %{state | pending: rest}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reply_pong(rest, state, acc, payload) do
    with {:ok, state} <- write(state, {:pong, payload}) do
      collect(rest, state, acc)
    end
  end

  defp write(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> {:ok, %{state | websocket: websocket, conn: conn}}
          {:error, _conn, reason} -> {:error, reason}
        end

      {:error, _websocket, reason} ->
        {:error, reason}
    end
  end

  defp receive_stream(state, deadline) do
    socket = Mint.HTTP.get_socket(state.conn)

    receive do
      message
      when is_tuple(message) and tuple_size(message) >= 2 and elem(message, 1) == socket ->
        case Mint.WebSocket.stream(state.conn, message) do
          {:ok, conn, responses} -> {:ok, %{state | conn: conn}, responses}
          {:error, _conn, reason, _responses} -> {:error, reason}
          :unknown -> receive_stream(state, deadline)
        end
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  # `URI.parse/1` only accepts a binary, and the behaviour's `url()` type says one
  # is expected; a caller passing anything else still gets the tagged error the
  # callback promises rather than a crash inside a third-party function.
  defp parse_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["ws", "wss"] and is_binary(host) ->
        {:ok, %{uri | port: uri.port || default_port(scheme)}, String.to_atom(scheme)}

      _other ->
        {:error, {:invalid_url, url}}
    end
  rescue
    URI.Error -> {:error, {:invalid_url, url}}
  end

  defp parse_url(url), do: {:error, {:invalid_url, url}}

  defp default_port("ws"), do: 80
  defp default_port("wss"), do: 443

  defp transport_scheme(:ws), do: :http
  defp transport_scheme(:wss), do: :https

  defp path(%URI{} = uri) do
    path = uri.path || "/"

    if uri.query, do: path <> "?" <> uri.query, else: path
  end

  defp ensure_host(headers, uri) do
    if Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "host" end) do
      headers
    else
      [{"host", host_header(uri)} | headers]
    end
  end

  defp host_header(%URI{scheme: scheme, host: host, port: port}) do
    if port == default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  defp connect_opts(opts) do
    timeout = timeout(opts)

    transport_opts =
      opts
      |> Keyword.get(:transport_opts, [])
      |> Keyword.put_new(:timeout, timeout)

    [transport_opts: transport_opts, protocols: [:http1]] ++
      Keyword.take(opts, [:proxy, :proxy_headers, :log])
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)

  defp now, do: System.monotonic_time(:millisecond)

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: now() + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - now(), 0)
end
