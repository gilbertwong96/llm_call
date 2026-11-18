defmodule LlmCall.HTTP do
  @moduledoc """
  The HTTP seam.

  A transport adapter performs one request, or streams one. The library ships
  `LlmCall.HTTP.Finch` as the default and reads the configured module from the
  call option, the provider declaration, `config :llm_call, http: Mod`, or that
  default — resolved at client-build time.

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
  @spec merge_headers([[{String.t(), String.t()}] | [{String.t(), String.t()}]]) :: [
          {String.t(), String.t()}
        ]
  def merge_headers(header_lists) do
    header_lists
    |> List.flatten()
    |> Enum.reduce([], fn {name, value}, acc ->
      name = name |> to_string() |> String.downcase()
      [{name, value} | Enum.reject(acc, fn {existing, _} -> existing == name end)]
    end)
    |> Enum.reverse()
  end

  @doc "Performs one request and returns the whole response."
  @callback request(Request.t(), keyword()) :: {:ok, response()} | {:error, term()}

  @doc """
  Performs one request, delivering `event()`s to `fun`.

  `acc` is threaded through the callback; `{:halt, acc}` stops the request. The
  last argument carries adapter options (a pool name, a pool timeout); the client
  forwards `http_opts` here.
  """
  @callback stream(
              Request.t(),
              acc,
              (event(), acc -> {:cont, acc} | {:halt, acc}),
              keyword()
            ) :: {:ok, acc} | {:error, term()}
            when acc: term()
end
