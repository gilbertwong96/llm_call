defmodule LlmCall.TestWSServer do
  @moduledoc """
  A minimal RFC 6455 server for transport and session tests.

  In `:echo` mode it echoes data frames (the `LlmCall.WS.Mint` tests). In
  `:responses` mode it answers a `response.create` frame with a full Responses
  event sequence; `:hold` mode sends only `response.created`, leaving the lane
  in flight for reconnect tests. It records every text frame it receives.
  """

  @key :llm_call_test_ws_server
  @listen_key :llm_call_test_ws_listen
  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def start(opts \\ []) do
    parent = self()
    mode = Keyword.get(opts, :mode, :echo)
    port = Keyword.get(opts, :port, 0)

    pid =
      spawn_link(fn ->
        {:ok, listen} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listen)
        send(parent, {:ws_port, self(), port, listen})
        serve(listen, %{buffer: "", mode: mode, pongs: [], frames: []})
      end)

    {port, listen} =
      receive do
        {:ws_port, ^pid, port, listen} -> {port, listen}
      after
        5_000 -> raise "the test WebSocket server did not start"
      end

    Process.put(@key, {pid, port})
    Process.put(@listen_key, listen)
    {pid, port}
  end

  def port do
    {_pid, port} = Process.get(@key) || raise "LlmCall.TestWSServer.start/0 was not called"
    port
  end

  def stop do
    case Process.get(@key) do
      nil ->
        :ok

      {pid, _port} ->
        if listen = Process.get(@listen_key), do: :gen_tcp.close(listen)
        send(pid, :stop)
    end
  end

  def url do
    {_pid, port} = Process.get(@key) || raise "LlmCall.TestWSServer.start/0 was not called"
    "ws://127.0.0.1:#{port}/ws"
  end

  def set_mode(mode) when mode in [:echo, :responses, :hold] do
    send(pid(), {:mode, mode, self()})

    receive do
      {:mode_set, ^mode} -> :ok
    after
      2_000 -> raise "the test WebSocket server did not switch mode"
    end
  end

  def frames do
    send(pid(), {:frames, self()})

    receive do
      {:frames, frames} -> frames
    after
      2_000 -> raise "the test WebSocket server did not answer frames/0"
    end
  end

  def send_frame(frame) do
    send(pid(), {:send, frame})
  end

  def close(code \\ 1000, reason \\ "") do
    send(pid(), {:close, code, reason})
  end

  defp pid do
    {pid, _port} = Process.get(@key) || raise "LlmCall.TestWSServer.start/0 was not called"
    pid
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

  defp serve(listen, state) do
    owner = self()
    acceptor = spawn_link(fn -> accept_loop(listen, owner) end)
    control(listen, acceptor, state)
  end

  defp accept_loop(listen, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        :gen_tcp.controlling_process(socket, owner)
        send(owner, {:accepted, socket})
        accept_loop(listen, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp control(listen, acceptor, state) do
    receive do
      {:accepted, socket} ->
        upgrade(socket)

        case loop(socket, state) do
          {:continue, state} -> control(listen, acceptor, state)
          {:stop, _state} -> :gen_tcp.close(listen)
        end

      {:mode, mode, from} ->
        send(from, {:mode_set, mode})
        control(listen, acceptor, %{state | mode: mode})

      {:frames, from} ->
        send(from, {:frames, Enum.reverse(state.frames)})
        control(listen, acceptor, state)

      :stop ->
        :gen_tcp.close(listen)
        Process.exit(acceptor, :kill)
    end
  end

  defp loop(socket, state) do
    receive do
      {:tcp, ^socket, data} ->
        {frames, rest} = parse_frames(state.buffer <> data, [])

        state =
          Enum.reduce(frames, %{state | buffer: rest}, fn frame, state ->
            handle_frame(socket, frame, state)
          end)

        :inet.setopts(socket, active: :once)
        loop(socket, state)

      {:tcp_closed, ^socket} ->
        {:continue, state}

      {:tcp_error, ^socket, _reason} ->
        {:continue, state}

      {:mode, mode, from} ->
        send(from, {:mode_set, mode})
        loop(socket, %{state | mode: mode})

      {:frames, from} ->
        send(from, {:frames, Enum.reverse(state.frames)})
        loop(socket, state)

      {:pongs, from} ->
        send(from, {:pongs, Enum.reverse(state.pongs)})
        loop(socket, state)

      {:send, frame} ->
        :gen_tcp.send(socket, encode_frame(frame))
        loop(socket, state)

      {:close, code, reason} ->
        :gen_tcp.send(socket, encode_frame({:close, code, reason}))
        :gen_tcp.close(socket)
        {:continue, state}

      :stop ->
        :gen_tcp.close(socket)
        {:stop, state}
    end
  end

  defp handle_frame(socket, {:text, data}, state) do
    state = %{state | frames: [{:text, data} | state.frames]}

    case state.mode do
      :echo -> :gen_tcp.send(socket, encode_frame({:text, data}))
      mode -> respond(socket, data, mode)
    end

    state
  end

  defp handle_frame(socket, {:binary, data}, state) do
    state = %{state | frames: [{:binary, data} | state.frames]}
    if state.mode == :echo, do: :gen_tcp.send(socket, encode_frame({:binary, data}))
    state
  end

  defp handle_frame(socket, :ping, state) do
    :gen_tcp.send(socket, encode_frame({:pong, ""}))
    state
  end

  defp handle_frame(_socket, :pong, state), do: %{state | pongs: [:pong | state.pongs]}
  defp handle_frame(_socket, {:close, _code, _reason}, state), do: state
  defp handle_frame(_socket, _frame, state), do: state

  defp respond(socket, data, mode) do
    with %{} = event <- :json.decode(data),
         "response.create" <- event["type"] do
      stream_id = event["stream_id"]
      hold? = mode == :hold

      for response_event <- response_events(stream_id, hold?) do
        :gen_tcp.send(socket, encode_frame({:text, encode(response_event)}))
      end
    else
      _other -> :ok
    end
  end

  defp response_events(stream_id, hold?) do
    created = %{
      "type" => "response.created",
      "response" => %{
        "id" => "resp_#{stream_id}",
        "object" => "response",
        "model" => "fake-ws",
        "status" => "in_progress"
      }
    }

    if hold? do
      [created]
    else
      [
        created,
        %{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{"type" => "message", "role" => "assistant"}
        },
        %{
          "type" => "response.content_part.added",
          "output_index" => 0,
          "part" => %{"type" => "output_text", "text" => ""}
        },
        %{"type" => "response.output_text.delta", "output_index" => 0, "delta" => "hello"},
        %{"type" => "response.content_part.done", "output_index" => 0},
        %{
          "type" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{"type" => "message"}
        },
        %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_#{stream_id}",
            "status" => "completed",
            "usage" => usage()
          }
        }
      ]
      |> Enum.map(&with_stream_id(&1, stream_id))
    end
  end

  defp with_stream_id(event, stream_id), do: Map.put(event, "stream_id", stream_id)

  defp usage do
    %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
  end

  defp encode(event), do: event |> :json.encode() |> IO.iodata_to_binary()

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
