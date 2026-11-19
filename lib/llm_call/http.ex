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

  @header_name_pattern ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @invalid_header_value_pattern ~r/[\x00-\x08\x0A-\x1F\x7F]/

  @doc """
  Merges header lists, keeping one value per name (case-insensitive).

  Later entries win, so a codec's protocol header overrides a caller's, and a
  caller's header overrides a provider default.
  """
  @spec merge_headers([[{String.t(), String.t()}]]) :: [{String.t(), String.t()}]
  def merge_headers(header_lists) do
    headers =
      header_lists
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    unless valid_headers?(headers) do
      raise ArgumentError, "headers must be a list of valid {name, value} string tuples"
    end

    headers
    |> Enum.reduce([], fn {name, value}, acc ->
      name = name |> to_string() |> String.downcase()
      [{name, value} | Enum.reject(acc, fn {existing, _} -> existing == name end)]
    end)
    |> Enum.reverse()
  end

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @default_pool LlmCall.Finch

  @doc """
  Parses a `Retry-After` header into milliseconds.

  Accepts delta-seconds or an IMF-fixdate HTTP-date; returns `nil` when the
  header is missing or malformed. Header names are matched case-insensitively.
  """
  @spec retry_after_ms([{String.t(), String.t()}]) :: non_neg_integer() | nil
  def retry_after_ms(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {name, value} ->
        if String.downcase(to_string(name)) == "retry-after" do
          parse_retry_after(value)
        else
          nil
        end

      _other ->
        nil
    end)
  end

  def retry_after_ms(_headers), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _other -> parse_http_date(value)
    end
  end

  defp parse_retry_after(_value), do: nil

  defp parse_http_date(value) do
    with [_, day, month, year, hour, minute, second] <-
           Regex.run(
             ~r/^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
             value
           ),
         {:ok, month} <- Map.fetch(@months, month),
         {:ok, datetime} <-
           NaiveDateTime.new(
             String.to_integer(year),
             month,
             String.to_integer(day),
             String.to_integer(hour),
             String.to_integer(minute),
             String.to_integer(second)
           ) do
      now = :calendar.universal_time()
      seconds = NaiveDateTime.to_erl(datetime) |> :calendar.datetime_to_gregorian_seconds()
      max(0, seconds - :calendar.datetime_to_gregorian_seconds(now)) * 1_000
    else
      _other -> nil
    end
  end

  @doc """
  Whether `headers` is a list of string `{name, value}` pairs (`nil` is allowed).
  """
  @spec valid_headers?(term()) :: boolean()
  def valid_headers?(nil), do: true

  def valid_headers?(headers) when is_list(headers) do
    Enum.all?(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        Regex.match?(@header_name_pattern, name) and
          not Regex.match?(@invalid_header_value_pattern, value)

      _other ->
        false
    end)
  end

  def valid_headers?(_headers), do: false

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

  defp forward(opts, %Request{receive_timeout: nil}) do
    Keyword.take(opts, [:pool_timeout, :request_timeout, :pool_strategy])
  end

  defp forward(opts, %Request{receive_timeout: timeout}) do
    opts
    |> Keyword.take([:pool_timeout, :request_timeout, :pool_strategy])
    |> Keyword.put(:receive_timeout, timeout)
  end
end
