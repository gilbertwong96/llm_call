defmodule LlmCall.TestHTTPServer do
  @moduledoc """
  A minimal HTTP/1.1 server for transport tests.

  Each test starts one server (`start/0`), points a provider at `url/0`, and
  configures the next response with `put_response/1` or `put_events/1`. The
  server records the requests it received (`requests/0`).

  Responses always carry `connection: close`, so Finch opens a new connection
  per request and one test cannot leak a pooled socket into another.
  """

  use GenServer

  @key :llm_call_test_http_server

  def start do
    {:ok, pid} = GenServer.start(__MODULE__, self())
    Process.put(@key, pid)
    pid
  end

  def stop do
    case Process.get(@key) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  def url do
    "http://127.0.0.1:" <> Integer.to_string(pid() |> GenServer.call(:port))
  end

  def put_response(response) when is_tuple(response),
    do: GenServer.call(pid(), {:response, response})

  def put_events(events) when is_list(events), do: GenServer.call(pid(), {:events, events})

  def requests, do: GenServer.call(pid(), :requests)

  def reset do
    GenServer.call(pid(), :reset)
  end

  defp pid do
    Process.get(@key) || raise "LlmCall.TestHTTPServer.start/0 was not called in this process"
  end

  @impl true
  def init(owner) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    server = self()
    acceptor = spawn_link(fn -> accept_loop(listen, server) end)
    :gen_tcp.controlling_process(listen, acceptor)

    {:ok,
     %{
       listen: listen,
       port: port,
       owner: owner,
       acceptor: acceptor,
       response: {:ok, %{status: 200, headers: [], body: "{}"}},
       events: nil,
       requests: []
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:requests, _from, state), do: {:reply, state.requests, state}

  def handle_call({:response, response}, _from, state),
    do: {:reply, :ok, %{state | response: response}}

  def handle_call({:events, events}, _from, state),
    do: {:reply, :ok, %{state | events: events}}

  def handle_call(:reset, _from, state) do
    {:reply, :ok,
     %{
       state
       | requests: [],
         events: nil,
         response: {:ok, %{status: 200, headers: [], body: "{}"}}
     }}
  end

  def handle_call({:next, request}, _from, state) do
    reply =
      if state.events do
        {:stream, state.events}
      else
        {:response, state.response}
      end

    {:reply, reply, %{state | requests: state.requests ++ [request]}}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  defp accept_loop(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handler = spawn(fn -> handle(socket, server) end)
        :gen_tcp.controlling_process(socket, handler)
        send(handler, :go)
        accept_loop(listen, server)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle(socket, server) do
    receive do
      :go -> :ok
    after
      5000 -> :ok
    end

    case read_request(socket) do
      {:ok, request} ->
        spec = GenServer.call(server, {:next, request})
        respond(socket, spec)

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket, acc \\ "") do
    if String.contains?(acc, "\r\n\r\n") do
      parse_request(acc, socket)
    else
      case :gen_tcp.recv(socket, 0, 5000) do
        {:ok, data} -> read_request(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_request(raw, socket) do
    [head, rest] = String.split(raw, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head, "\r\n")

    headers =
      Enum.map(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    content_length =
      case List.keyfind(headers, "content-length", 0) do
        {_name, value} -> String.to_integer(value)
        nil -> 0
      end

    with {:ok, body} <- read_body(socket, rest, content_length) do
      [method, path | _rest] = String.split(request_line, " ")

      {:ok,
       %{
         method: method |> String.downcase() |> String.to_atom(),
         path: path,
         headers: headers,
         body: body
       }}
    end
  end

  defp read_body(_socket, acc, length) when byte_size(acc) >= length, do: {:ok, acc}

  defp read_body(socket, acc, length) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} -> read_body(socket, acc <> data, length)
      {:error, reason} -> {:error, reason}
    end
  end

  defp respond(socket, {:response, {:ok, %{delay: delay} = response}}) do
    Process.sleep(delay)
    respond(socket, {:response, {:ok, Map.delete(response, :delay)}})
  end

  defp respond(_socket, {:response, {:error, _reason}}), do: :ok

  defp respond(socket, {:response, {:ok, %{status: status, headers: headers, body: body}}}) do
    headers =
      [{"content-length", Integer.to_string(byte_size(body))}, {"connection", "close"}] ++
        headers

    send_response(socket, status, headers, body)
  end

  defp respond(socket, {:stream, events}), do: stream_response(socket, events)

  defp stream_response(socket, events) do
    status =
      Enum.find_value(events, 200, fn
        {:status, status} -> status
        _event -> nil
      end)

    headers =
      Enum.find_value(events, [], fn
        {:headers, headers} -> headers
        _event -> nil
      end)

    headers =
      [
        {"content-type", "text/event-stream"},
        {"transfer-encoding", "chunked"},
        {"connection", "close"}
      ] ++
        headers

    send_head(socket, status, headers)

    result =
      Enum.reduce_while(events, :ok, fn
        {:data, chunk}, :ok ->
          send_chunk(socket, chunk)
          Process.sleep(1)
          {:cont, :ok}

        {:error, _reason}, :ok ->
          {:halt, :aborted}

        _event, :ok ->
          {:cont, :ok}
      end)

    if result == :ok, do: :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp send_chunk(socket, chunk) do
    :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
  end

  defp send_response(socket, status, headers, body) do
    send_head(socket, status, headers)
    :gen_tcp.send(socket, body)
  end

  defp send_head(socket, status, headers) do
    header_lines = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " OK\r\n",
      header_lines,
      "\r\n"
    ])
  end
end
