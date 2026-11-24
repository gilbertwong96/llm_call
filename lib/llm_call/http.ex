defmodule LlmCall.HTTP do
  @moduledoc """
  HTTP transport, backed by Finch.

  There is one transport. The pool is named `LlmCall.Finch`; the application
  starts it unless that name is already taken, so a host can own it by starting
  its pool first. Pass `http_opts: [name: MyPool]` to a provider or client to use
  a pool from your own supervision tree.

  `request/2` and `stream/4` forward exactly four transport options: `:name`
  (the pool), plus Finch's `:pool_timeout`, `:request_timeout`, and
  `:pool_strategy`. `LlmCall.Provider` rejects any other key, so a typo cannot be
  dropped silently. The per-request read timeout is not one of them: it comes
  from the request itself, which the client fills from its `timeout:` option.

  Neither function raises for a transport failure: a Finch exception or exit —
  a pool checkout timeout is a `RuntimeError` — returns `{:error, {:exception,
  message}}`, which the transport-reason mapping carries as `reason: :exception`.
  `stream/4`'s reducer runs inside that protected region, so an `ArgumentError` or
  `RuntimeError` the callback itself raises is reported the same way.

  ## Streaming events

  `stream/4` delivers, in order:

    * `{:status, status}` — before any body bytes, so a caller can stop on a
      non-`2xx` response instead of treating an error body as an empty stream;
    * `{:headers, headers}`;
    * `{:data, binary}` — zero or more body chunks.

  Returning `{:halt, acc}` from the callback stops the request and closes the
  connection.
  """
  defmodule Request do
    @moduledoc """
    One HTTP request, fully resolved by the client.

    `inspect` omits `headers`, which carry the credential.
    """

    @derive {Inspect, except: [:headers]}

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
        Regex.match?(@header_name_pattern, name) and valid_header_value?(value)

      _other ->
        false
    end)
  end

  def valid_headers?(_headers), do: false

  # A header value must be printable ASCII with no leading or trailing whitespace.
  # Mint rejects anything else too, but its message embeds the value with `inspect/1`,
  # so a non-ASCII byte in an api_key would reach a log through the transport error.
  # Catching it while the client is built keeps the value out of the message.
  defp valid_header_value?(value) do
    value == String.trim(value) and printable_ascii?(value)
  end

  defp printable_ascii?(<<>>), do: true

  defp printable_ascii?(<<byte, rest::binary>>) when byte in 0x20..0x7E or byte == 0x09,
    do: printable_ascii?(rest)

  defp printable_ascii?(_value), do: false

  @doc """
  Joins a base URL, a request path, and an already-encoded query.

  The base URL's path is kept, so a vendor prefix (`https://…/openai`) survives
  and the path is appended to it; a trailing slash on either side never doubles.
  The query is set on the URI struct rather than glued onto the string, which is
  what keeps a `?` in the base URL from ending up inside the path.

  `base_url` may be a string or an already parsed `%URI{}`, which lets the
  WebSocket handshake reuse it after changing the scheme.
  """
  @spec build_url(String.t() | URI.t(), String.t(), String.t() | nil) :: String.t()
  def build_url(base_url, path, query \\ nil)

  def build_url(base_url, path, query) when is_binary(base_url),
    do: build_url(URI.parse(base_url), path, query)

  def build_url(%URI{} = base, path, query) when is_binary(path) do
    URI.to_string(%{
      base
      | path: join_path(base.path, path),
        query: empty_to_nil(query),
        fragment: nil
    })
  end

  # An empty query string renders as a trailing `?`, which is not the same URL.
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(query), do: query

  defp join_path(base_path, path) when base_path in [nil, ""], do: path
  defp join_path(base_path, path), do: String.trim_trailing(base_path, "/") <> path

  @doc "Performs one request and returns the whole response."
  @spec request(Request.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(%Request{} = request, opts \\ []) do
    pool = Keyword.get(opts, :name, @default_pool)

    with :ok <- validate_pool(pool) do
      finch_request = build(request)
      finch_opts = forward(opts, request)

      try do
        case Finch.request(finch_request, pool, finch_opts) do
          {:ok, %Finch.Response{status: status, headers: headers, body: body}} ->
            {:ok, %{status: status, headers: headers, body: body}}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        error in [ArgumentError, RuntimeError] ->
          {:error, {:exception, Exception.message(error)}}
      catch
        :exit, reason -> {:error, {:exception, exit_message(reason)}}
      end
    end
  end

  @doc """
  Performs one request, delivering `event()`s to `fun`.

  `acc` is threaded through the callback; `{:halt, acc}` stops the request and
  closes the connection. The last argument carries the transport options
  described in the module documentation: `:name`, `:pool_timeout`,
  `:request_timeout`, and `:pool_strategy`.
  """
  @spec stream(
          Request.t(),
          acc,
          (event(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) :: {:ok, acc} | {:error, term(), acc} | {:error, term()}
        when acc: term()
  def stream(%Request{} = request, acc, fun, opts) when is_function(fun, 2) do
    pool = Keyword.get(opts, :name, @default_pool)

    reducer = fn
      {:status, status}, acc -> fun.({:status, status}, acc)
      {:headers, headers}, acc -> fun.({:headers, headers}, acc)
      {:data, data}, acc -> fun.({:data, data}, acc)
      {:trailers, _trailers}, acc -> {:cont, acc}
    end

    with :ok <- validate_pool(pool) do
      finch_request = build(request)
      finch_opts = forward(opts, request)

      try do
        # Finch's own shapes are this function's: on a failure the accumulator it returns
        # holds whatever the reducer had already seen — the status and headers of an error
        # response, for instance — so `LlmCall.Stream` can still report them.
        Finch.stream_while(finch_request, pool, acc, reducer, finch_opts)
      rescue
        error in [ArgumentError, RuntimeError] ->
          {:error, {:exception, Exception.message(error)}}
      catch
        :exit, reason -> {:error, {:exception, exit_message(reason)}}
      end
    end
  end

  # A missing pool makes Finch raise `unknown registry`, before any reducer runs.
  # Checking it here keeps a client typo inside the error-tuple contract.
  defp validate_pool(pool) do
    if pool_alive?(pool), do: :ok, else: {:error, {:unknown_pool, pool}}
  rescue
    _error -> {:error, {:unknown_pool, pool}}
  end

  defp exit_message(reason) do
    "transport exited: " <> exit_reason(reason)
  end

  # `Exception.format_banner/2` takes a kind, not an exception, so an exit whose
  # reason is `{exception, stacktrace}` has to go through the 3-arity form.
  defp exit_reason({exception, stacktrace}) when is_exception(exception) and is_list(stacktrace),
    do: Exception.format_banner(:error, exception, stacktrace)

  defp exit_reason(reason), do: Exception.format_exit(reason)

  defp pool_alive?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp pool_alive?(name) do
    case GenServer.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
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
