defmodule LlmCall.TestProxy do
  @moduledoc """
  A minimal HTTP forward proxy for WebSocket tests.

  It accepts one absolute-form `GET` (Mint's `UnsafeProxy` for `ws://`),
  rewrites the request line to origin form, connects to the target, and relays
  bytes both ways. Only `ws://` is covered; `wss://` would need `CONNECT`.
  """

  @key :llm_call_test_proxy

  def start(target_url) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    target = URI.parse(target_url)
    pid = spawn_link(fn -> accept_loop(listen, target) end)
    Process.put(@key, {pid, port, listen})
    {pid, port}
  end

  def stop do
    case Process.get(@key) do
      nil ->
        :ok

      {pid, _port, listen} ->
        :gen_tcp.close(listen)
        send(pid, :stop)
        :ok
    end
  end

  defp accept_loop(listen, target) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handle(socket, target)
        accept_loop(listen, target)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle(socket, target) do
    with {:ok, head, rest} <- read_head(socket, ""),
         [request_line | headers] <- String.split(head, "\r\n"),
         [method, url, version] <- String.split(request_line, " "),
         %URI{path: path, query: query} <- URI.parse(url),
         {:ok, upstream} <- connect_target(target) do
      path = if query, do: path <> "?" <> query, else: path

      :gen_tcp.send(upstream, [
        method,
        " ",
        path,
        " ",
        version,
        "\r\n",
        Enum.join(headers, "\r\n"),
        "\r\n\r\n",
        rest
      ])

      relay_both(socket, upstream)
    else
      _other -> :gen_tcp.close(socket)
    end
  end

  defp connect_target(%URI{host: host, port: port}) do
    :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000)
  end

  defp relay_both(client, upstream) do
    client_to_upstream = spawn(fn -> await_go(client, upstream) end)
    upstream_to_client = spawn(fn -> await_go(upstream, client) end)
    :gen_tcp.controlling_process(client, client_to_upstream)
    :gen_tcp.controlling_process(upstream, upstream_to_client)
    send(client_to_upstream, :go)
    send(upstream_to_client, :go)
  end

  defp await_go(from, to) do
    receive do
      :go -> relay(from, to)
    end
  end

  defp relay(from, to) do
    case :gen_tcp.recv(from, 0, 60_000) do
      {:ok, data} ->
        :gen_tcp.send(to, data)
        relay(from, to)

      {:error, _reason} ->
        :gen_tcp.close(to)
    end
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      [head, rest] = String.split(acc, "\r\n\r\n", parts: 2)
      {:ok, head, rest}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_head(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
