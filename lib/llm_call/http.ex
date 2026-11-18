defmodule LlmCall.HTTP do
  @moduledoc """
  HTTP transport, backed by Finch.

  There is one transport. The pool is named `LlmCall.Finch` and started by the
  application; pass `http_opts: [name: MyPool]` to a provider or client to use a
  pool from your own supervision tree.

  ## Streaming events

  `stream/3` delivers, in order:

    * `{:status, status}` — before any body bytes, so a caller can stop on a
      non-`2xx` response instead of treating an error body as an empty stream;
    * `{:headers, headers}`;
    * `{:data, binary}` — zero or more body chunks.

  Returning `{:halt, acc}` from the callback stops the request and closes the
  connection.
  """

  defmodule Request do
    @moduledoc "One HTTP request, fully resolved by the client."

    @type method :: :get | :post

    @type t :: %__MODULE__{
            method: method(),
            url: String.t(),
            headers: [{String.t(), String.t()}],
            body: iodata() | nil,
            receive_timeout: timeout()
          }

    defstruct [:method, :url, :headers, :body, :receive_timeout]

    @doc "Builds a request for a `POST`."
    @spec post(String.t(), [{String.t(), String.t()}], iodata(), timeout()) :: t()
    def post(url, headers, body, receive_timeout) do
      %__MODULE__{
        method: :post,
        url: url,
        headers: headers,
        body: body,
        receive_timeout: receive_timeout
      }
    end

    @doc "Builds a request for a `GET`."
    @spec get(String.t(), [{String.t(), String.t()}], timeout()) :: t()
    def get(url, headers, receive_timeout) do
      %__MODULE__{
        method: :get,
        url: url,
        headers: headers,
        body: nil,
        receive_timeout: receive_timeout
      }
    end
  end

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type event ::
          {:status, non_neg_integer()}
          | {:headers, [{String.t(), String.t()}]}
          | {:data, binary()}

  @doc """
  Merges header lists, keeping one value per name (case-insensitive).

  Later entries win, so a codec's protocol header overrides a caller's, and a
  caller's header overrides a provider default.
  """
  @spec merge_headers([[{String.t(), String.t()}]]) :: [{String.t(), String.t()}]
  def merge_headers(header_lists) do
    header_lists
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce([], fn {name, value}, acc ->
      name = name |> to_string() |> String.downcase()
      [{name, value} | Enum.reject(acc, fn {existing, _} -> existing == name end)]
    end)
    |> Enum.reverse()
  end

  @default_pool LlmCall.Finch

  @doc "Performs one request and returns the whole response."
  @spec request(Request.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(%Request{} = request, opts \\ []) do
    pool = Keyword.get(opts, :name, @default_pool)

    case Finch.request(build(request), pool, forward(opts, request)) do
      {:ok, %Finch.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: headers, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Performs one request, delivering `event()`s to `fun`.

  `acc` is threaded through the callback; `{:halt, acc}` stops the request. The
  last argument carries transport options (a pool name, a pool timeout); the
  client forwards `http_opts` here.
  """
  @spec stream(
          Request.t(),
          acc,
          (event(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) :: {:ok, acc} | {:error, term()}
        when acc: term()
  def stream(%Request{} = request, acc, fun, opts) when is_function(fun, 2) do
    pool = Keyword.get(opts, :name, @default_pool)

    reducer = fn
      {:status, status}, acc -> fun.({:status, status}, acc)
      {:headers, headers}, acc -> fun.({:headers, headers}, acc)
      {:data, data}, acc -> fun.({:data, data}, acc)
      {:trailers, _trailers}, acc -> {:cont, acc}
    end

    case Finch.stream_while(build(request), pool, acc, reducer, forward(opts, request)) do
      {:ok, acc} -> {:ok, acc}
      {:error, reason, _acc} -> {:error, reason}
    end
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
