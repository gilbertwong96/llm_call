defmodule LlmCall.HTTP.Finch do
  @moduledoc """
  The default transport, backed by Finch.

  `LlmCall.Application` starts a pool named `LlmCall.Finch`; pass
  `http_opts: [name: MyPool]` to use another one (started by your own
  supervision tree). Connect timeouts belong to the pool configuration; the
  request's `receive_timeout` is forwarded as Finch's `:receive_timeout`.
  """

  @behaviour LlmCall.HTTP

  alias LlmCall.HTTP.Request

  @default_pool LlmCall.Finch

  @impl true
  @spec request(Request.t(), keyword()) :: {:ok, LlmCall.HTTP.response()} | {:error, term()}
  def request(%Request{} = request, opts \\ []) do
    pool = Keyword.get(opts, :name, @default_pool)

    case Finch.request(build(request), pool, forward(opts, request)) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: headers, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec stream(
          Request.t(),
          acc,
          (LlmCall.HTTP.event(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def stream(%Request{} = request, acc, fun, opts) when is_function(fun, 2) do
    pool = Keyword.get(opts, :name, @default_pool)

    reducer = fn
      {:status, status}, acc -> fun.({:status, status}, acc)
      {:headers, headers}, acc -> fun.({:headers, headers}, acc)
      {:data, data}, acc -> fun.({:data, data}, acc)
    end

    Finch.stream_while(build(request), pool, acc, reducer, forward(opts, request))
  end

  defp build(%Request{} = request) do
    headers = Enum.map(request.headers, fn {name, value} -> {to_string(name), value} end)

    Finch.build(request.method, request.url, headers, request.body)
  end

  defp forward(opts, %Request{receive_timeout: nil}), do: Keyword.take(opts, [:pool_timeout])

  defp forward(opts, %Request{receive_timeout: timeout}) do
    opts
    |> Keyword.take([:pool_timeout])
    |> Keyword.put(:receive_timeout, timeout)
  end
end
