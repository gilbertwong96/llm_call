defmodule LlmCall.TestWSServer do
  @moduledoc """
  A minimal RFC 6455 echo server for `LlmCall.WS.Mint` tests.

  The server performs the upgrade handshake, echoes client data frames, answers
  pings, and lets the test push frames with `send_frame/2` or close with
  `close/3`.
  """

  @key :llm_call_test_ws_server
  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def start do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listen)
        send(parent, {:ws_port, self(), port})
        {:ok, socket} = :gen_tcp.accept(listen)
        :gen_tcp.close(listen)
        upgrade(socket)
        loop(socket, "", true, [])
      end)

    port =
      receive do
        {:ws_port, ^pid, port} -> port
      after
        5_000 -> raise "the test WebSocket server did not start"
      end

    Process.put(@key, {pid, port})
    {pid, port}
  end

  def stop do
    case Process.get(@key) do
      nil -> :ok
      {pid, _port} -> send(pid, :stop)
    end
  end

  def url do
    {_pid, port} = Process.get(@key) || raise "LlmCall.TestWSServer.start/0 was not called"
    "ws://127.0.0.1:#{port}/ws"
  end

  def send_frame(frame) do
    {pid, _port} = Process.get(@key) || raise "LlmCall.TestWSServer.start/0 was not called"
    send(pid, {:send, frame})
  end

  def close(code \\ 1000, reason \\ "") do
    {pid, _port} = Process.get(@key) || raise "LlmCall.TestWSServer.start/0 was not called"
    send(pid, {:close, code, reason})
  end

  defp upgrade(socket) do
    key = socket |> read_head("") |> websocket_key()
    accept = Base.encode64(:crypto.hash(:sha, key <> @guid))

    :gen_tcp.send(socket, [
      "HTTP/1.1 101 Switching Protocols\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Accept: ",
      accept,
      "\r\n\r\n"
    ])

    :inet.setopts(socket, active: :once)
  end

  defp websocket_key(request) do
    request
    |> String.split("\r\n")
    |> Enum.find_value(fn line -> header_value(line, "sec-websocket-key") end)
  end

  defp header_value(line, expected) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> if String.downcase(name) == expected, do: String.trim(value)
      _other -> nil
    end
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      read_head(socket, acc <> data)
    end
  end

  defp loop(socket, buffer, echo?, pongs) do
    receive do
      {:tcp, ^socket, data} ->
        {frames, rest} = parse_frames(buffer <> data, [])

        {echo?, pongs} =
          Enum.reduce(frames, {echo?, pongs}, fn frame, acc ->
            handle_frame(socket, frame, acc)
          end)

        :inet.setopts(socket, active: :once)
        loop(socket, rest, echo?, pongs)

      {:send, frame} ->
        :gen_tcp.send(socket, encode_frame(frame))
        loop(socket, buffer, echo?, pongs)

      {:pongs, from} ->
        send(from, {:pongs, Enum.reverse(pongs)})
        loop(socket, buffer, echo?, pongs)

      {:close, code, reason} ->
        :gen_tcp.send(socket, encode_frame({:close, code, reason}))
        :gen_tcp.close(socket)

      :stop ->
        :gen_tcp.close(socket)
    end
  end

  defp handle_frame(socket, {:text, data}, {true, pongs}) do
    :gen_tcp.send(socket, encode_frame({:text, data}))
    {true, pongs}
  end

  defp handle_frame(socket, {:binary, data}, {true, pongs}) do
    :gen_tcp.send(socket, encode_frame({:binary, data}))
    {true, pongs}
  end

  defp handle_frame(socket, :ping, {echo?, pongs}) do
    :gen_tcp.send(socket, encode_frame({:pong, ""}))
    {echo?, pongs}
  end

  defp handle_frame(_socket, :pong, {echo?, pongs}) do
    {echo?, [:pong | pongs]}
  end

  defp handle_frame(_socket, {:close, _code, _reason}, {echo?, pongs}) do
    {echo?, pongs}
  end

  defp handle_frame(_socket, _frame, acc), do: acc

  defp parse_frames(buffer, acc) do
    case decode_frame(buffer) do
      {:ok, frame, rest} -> parse_frames(rest, [frame | acc])
      :more -> {Enum.reverse(acc), buffer}
    end
  end

  defp decode_frame(<<_fin::1, _rsv::3, opcode::4, mask::1, len::7, rest::binary>>) do
    with {:ok, len, rest} <- extended_length(len, rest),
         {:ok, key, rest} <- mask_key(mask, rest),
         {:ok, payload, rest} <- take(rest, len) do
      payload = if mask == 1, do: unmask(payload, key), else: payload

      case opcode do
        1 -> {:ok, {:text, payload}, rest}
        2 -> {:ok, {:binary, payload}, rest}
        8 -> {:ok, {:close, close_code(payload), close_reason(payload)}, rest}
        9 -> {:ok, :ping, rest}
        10 -> {:ok, :pong, rest}
        _ -> {:ok, :unknown, rest}
      end
    end
  end

  defp decode_frame(_buffer), do: :more

  defp extended_length(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
  defp extended_length(127, <<len::64, rest::binary>>), do: {:ok, len, rest}
  defp extended_length(len, rest) when len < 126, do: {:ok, len, rest}
  defp extended_length(_len, _rest), do: :more

  defp mask_key(1, <<key::binary-size(4), rest::binary>>), do: {:ok, key, rest}
  defp mask_key(0, rest), do: {:ok, nil, rest}
  defp mask_key(_mask, _rest), do: :more

  defp take(binary, len) when byte_size(binary) >= len do
    {:ok, binary_part(binary, 0, len), binary_part(binary, len, byte_size(binary) - len)}
  end

  defp take(_binary, _len), do: :more

  defp unmask(payload, key) do
    key_stream = :binary.copy(key, div(byte_size(payload), 4) + 1)

    for {byte, mask} <- Enum.zip(:binary.bin_to_list(payload), :binary.bin_to_list(key_stream)),
        into: <<>>,
        do: <<Bitwise.bxor(byte, mask)>>
  end

  defp close_code(<<code::16, _rest::binary>>), do: code
  defp close_code(_payload), do: 1000

  defp close_reason(<<_code::16, reason::binary>>), do: reason
  defp close_reason(_payload), do: ""

  defp encode_frame({:text, data}), do: encode(1, data)
  defp encode_frame({:binary, data}), do: encode(2, data)
  defp encode_frame({:close, code, reason}), do: encode(8, <<code::16, reason::binary>>)
  defp encode_frame({:ping, data}), do: encode(9, data)
  defp encode_frame({:pong, data}), do: encode(10, data)
  defp encode_frame(:pong), do: encode(10, "")

  defp encode(opcode, payload) do
    header =
      case byte_size(payload) do
        len when len < 126 -> <<1::1, 0::3, opcode::4, 0::1, len::7>>
        len when len < 65_536 -> <<1::1, 0::3, opcode::4, 0::1, 126::7, len::16>>
        len -> <<1::1, 0::3, opcode::4, 0::1, 127::7, len::64>>
      end

    header <> payload
  end
end
