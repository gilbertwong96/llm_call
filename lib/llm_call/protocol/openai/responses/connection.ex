defmodule LlmCall.Protocol.OpenAI.Responses.Connection do
  @moduledoc """
  A WebSocket connection for OpenAI Responses (`wss://…/v1/responses`).

  It owns one WebSocket connection and multiplexes `response.create` calls
  over it. Each call names a `stream_id` lane (generated when omitted);
  events are decoded per lane by `LlmCall.Protocol.OpenAI.Responses` and
  delivered to the `%Stream{}` returned by `create/3`.

  `previous_response_id`, `store` and `include` belong in the request's
  `provider_options`, exactly as on HTTP. `steer/3` sends `response.steer` for an
  active lane; `cancel/2` sends `response.cancel` and ends the lane.

  ## Reconnect

  A Responses WebSocket may live for at most 60 minutes. The connection reconnects
  before that (`:max_age_ms`, default 55 minutes) and on an unexpected close,
  with exponential backoff (`:retry_delay_ms` 5s, `:max_retry_delay_ms` 60s) and
  a bounded number of attempts (`:max_reconnect_attempts`, default 5; `:infinity`
  to retry forever).

  A failed reconnect does not stop the connection: it becomes `:disconnected`,
  `create/3` and `steer/3` return a `:transport` error, and the retry loop keeps
  running until the budget is exhausted. `reconnect/1` attempts immediately and
  resets the budget.

  An in-flight lane cannot be resumed: its subscriber receives a `:transport`
  error. Continuing a conversation across a reconnect is the caller's decision,
  using `previous_response_id` and the input it wants to resend.
  """

  use GenServer

  alias LlmCall.{Client, Error}
  alias LlmCall.Protocol.OpenAI.Responses
  alias LlmCall.WS

  @default_max_age 55 * 60 * 1000
  @default_timeout 30_000
  @stream_id_pattern ~r/\A[A-Za-z0-9_.-]{1,256}\z/

  @type t :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Starts one response on `stream_id` (generated when omitted) and returns its
  event stream. `stream_id` must be unique among active lanes.

  The stream must be reduced by the caller of this function: the connection
  sends that process the events. Reducing it elsewhere raises `ArgumentError`.
  """
  @spec create(t(), LlmCall.Request.t(), keyword()) ::
          {:ok, LlmCall.Protocol.OpenAI.Responses.Connection.Stream.t()} | {:error, Error.t()}
  def create(connection, request, opts \\ []) do
    GenServer.call(connection, {:create, request, opts}, @default_timeout)
  end

  @doc """
  Queues `input` for the active response on `stream_id` with `response.steer`.

  `input` is wire-shaped (a string or a list of Responses input items); the
  connection does not reinterpret it.
  """
  @spec steer(t(), String.t(), term()) :: :ok | {:error, Error.t()}
  def steer(connection, stream_id, input) do
    GenServer.call(connection, {:steer, stream_id, input}, @default_timeout)
  end

  @doc "Cancels the lane's active response and ends it."
  @spec cancel(t(), String.t()) :: :ok | {:error, Error.t()}
  def cancel(connection, stream_id) do
    GenServer.call(connection, {:cancel, stream_id}, @default_timeout)
  end

  @doc """
  Reconnects now. In-flight lanes receive a `:transport` error; idle lanes are
  unaffected because there are none.
  """
  @spec reconnect(t()) :: :ok | {:error, Error.t()}
  def reconnect(connection), do: GenServer.call(connection, :reconnect, @default_timeout)

  @doc """
  The provider response id for `stream_id`, if the lane has produced one.

  `response.created` carries it; use it as `previous_response_id` in a later
  request. Active lanes answer immediately; completed lanes keep the last 32 ids.
  """
  @spec response_id(t(), String.t()) :: {:ok, String.t()} | :error
  def response_id(connection, stream_id) do
    GenServer.call(connection, {:response_id, stream_id}, @default_timeout)
  end

  @doc "Closes the WebSocket and stops the process."
  @spec close(t()) :: :ok
  def close(connection), do: GenServer.stop(connection, :normal)

  @impl true
  def init(opts) do
    case connection_config(opts) do
      {:ok, config} ->
        case connect(config.client, config.ws, config.ws_opts) do
          {:ok, conn} -> {:ok, schedule_max_age(%{config | conn: conn})}
          {:error, reason} -> {:stop, {:connect_failed, reason}}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp connection_config(opts) do
    client = Keyword.get(opts, :client)
    ws = Keyword.get(opts, :ws, WS.Mint)
    ws_opts = Keyword.get(opts, :ws_opts, [])
    max_age = Keyword.get(opts, :max_age_ms, @default_max_age)
    reconnect? = Keyword.get(opts, :reconnect, true)
    max_attempts = Keyword.get(opts, :max_reconnect_attempts, 5)
    retry_delay = Keyword.get(opts, :retry_delay_ms, 5_000)
    max_retry_delay = Keyword.get(opts, :max_retry_delay_ms, 60_000)

    with :ok <- validate_client(client),
         :ok <- validate_max_age(max_age),
         :ok <- validate_attempts(max_attempts),
         :ok <- validate_delays(retry_delay, max_retry_delay) do
      {:ok,
       %{
         client: client,
         ws: ws,
         ws_opts: ws_opts,
         conn: nil,
         status: :connected,
         max_age: max_age,
         reconnect?: reconnect?,
         max_reconnect_attempts: max_attempts,
         retry_delay: retry_delay,
         max_retry_delay: max_retry_delay,
         retry_attempts: 0,
         max_age_timer: nil,
         max_age_ref: nil,
         retry_timer: nil,
         retry_ref: nil,
         lanes: %{},
         finished: []
       }}
    end
  end

  defp validate_client(%Client{}), do: :ok
  defp validate_client(_client), do: {:error, :client_required}

  defp validate_max_age(max_age) when is_integer(max_age) and max_age > 0, do: :ok
  defp validate_max_age(_max_age), do: {:error, :invalid_max_age}

  defp validate_attempts(:infinity), do: :ok
  defp validate_attempts(attempts) when is_integer(attempts) and attempts >= 0, do: :ok
  defp validate_attempts(_attempts), do: {:error, :invalid_max_reconnect_attempts}

  defp validate_delays(retry_delay, max_retry_delay)
       when is_integer(retry_delay) and retry_delay > 0 and
              is_integer(max_retry_delay) and max_retry_delay >= retry_delay,
       do: :ok

  defp validate_delays(_retry_delay, _max_retry_delay), do: {:error, :invalid_retry_delay}

  @impl true
  def handle_call({:create, _request, _opts}, _from, %{status: :disconnected} = state) do
    {:reply, {:error, disconnected_error()}, state}
  end

  def handle_call({:create, request, opts}, {pid, _tag}, state) do
    stream_id =
      Keyword.get(opts, :stream_id) ||
        "lane-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- validate_stream_id(stream_id),
         false <- Map.has_key?(state.lanes, stream_id),
         {:ok, encoded} <- Responses.encode_request(request, state.client.config),
         {:ok, stream_state} <- Responses.init_stream(request, state.client.config),
         {:ok, json} <- encode(state, create_event(encoded.body, stream_id)),
         {:ok, conn} <- state.ws.send_frame(state.conn, {:text, json}) do
      ref = make_ref()

      lane = %{
        ref: ref,
        subscriber: pid,
        state: stream_state,
        response_id: nil
      }

      stream = %LlmCall.Protocol.OpenAI.Responses.Connection.Stream{
        connection: self(),
        stream_id: stream_id,
        ref: ref,
        subscriber: pid
      }

      state = %{state | conn: conn, lanes: Map.put(state.lanes, stream_id, lane)}
      {:reply, {:ok, stream}, state}
    else
      true ->
        {:reply, {:error, validation("stream_id #{inspect(stream_id)} is already in use")}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:error, reason} ->
        state = send_failure(state, reason)
        {:reply, {:error, transport(reason)}, state}
    end
  end

  def handle_call({:steer, _stream_id, _input}, _from, %{status: :disconnected} = state) do
    {:reply, {:error, disconnected_error()}, state}
  end

  def handle_call({:steer, stream_id, input}, _from, state) do
    with {:ok, _lane} <- Map.fetch(state.lanes, stream_id),
         {:ok, json} <-
           encode(state, %{"type" => "response.steer", "stream_id" => stream_id, "input" => input}),
         {:ok, conn} <- state.ws.send_frame(state.conn, {:text, json}) do
      {:reply, :ok, %{state | conn: conn}}
    else
      :error ->
        {:reply, {:error, validation("unknown stream_id #{inspect(stream_id)}")}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:error, reason} ->
        state = send_failure(state, reason)
        {:reply, {:error, transport(reason)}, state}
    end
  end

  def handle_call({:response_id, stream_id}, _from, state) do
    case Map.fetch(state.lanes, stream_id) do
      {:ok, %{response_id: response_id}} when is_binary(response_id) ->
        {:reply, {:ok, response_id}, state}

      {:ok, _active_without_id} ->
        {:reply, :error, state}

      :error ->
        case List.keyfind(state.finished, stream_id, 0) do
          {^stream_id, response_id} -> {:reply, {:ok, response_id}, state}
          nil -> {:reply, :error, state}
        end
    end
  end

  def handle_call({:cancel, stream_id}, _from, state) do
    case Map.fetch(state.lanes, stream_id) do
      {:ok, lane} ->
        state = send_cancel(state, stream_id, lane.response_id)
        state = remember_response(state, stream_id, lane.response_id)
        send(lane.subscriber, {:responses_ws, lane.ref, :done})
        {:reply, :ok, %{state | lanes: Map.delete(state.lanes, stream_id)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:reconnect, _from, state) do
    state = %{state | retry_attempts: 0}

    case do_reconnect(state, :reconnected) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, error, state} -> {:reply, {:error, transport(error)}, state}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, ref}, state) do
    case Enum.find(state.lanes, fn {_stream_id, lane} -> lane.ref == ref end) do
      nil ->
        {:noreply, state}

      {stream_id, lane} ->
        state = send_cancel(state, stream_id, lane.response_id)
        {:noreply, %{state | lanes: Map.delete(state.lanes, stream_id)}}
    end
  end

  @impl true
  def handle_info({:max_age, ref}, %{max_age_ref: ref} = state) do
    handle_max_age(state)
  end

  def handle_info({:max_age, _stale_ref}, state), do: {:noreply, state}

  def handle_info({:retry, ref}, %{retry_ref: ref} = state) do
    state = %{state | retry_timer: nil, retry_ref: nil}

    case connect(state.client, state.ws, state.ws_opts) do
      {:ok, conn} -> {:noreply, connected(%{state | conn: conn})}
      {:error, _error} -> {:noreply, schedule_retry(state)}
    end
  end

  def handle_info({:retry, _stale_ref}, state), do: {:noreply, state}

  def handle_info(message, %{status: :connected} = state) when is_tuple(message) do
    case safe_feed(state.ws, state.conn, message) do
      {:ok, frames, conn} ->
        case dispatch(frames, %{state | conn: conn}) do
          {:ok, state} -> {:noreply, state}
          {:disconnect, reason, state} -> disconnect(state, reason)
        end

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = cancel_max_age(state)
    state = cancel_retry(state)
    safe_close(state.ws, state.conn)
    :ok
  end

  defp connect(client, ws, ws_opts) do
    ws.connect(ws_url(client), client.headers, ws_opts)
  end

  defp ws_url(%Client{base_url: base_url}) do
    uri = URI.parse(base_url)

    scheme =
      case uri.scheme do
        "https" -> "wss"
        "http" -> "ws"
        scheme -> scheme
      end

    path = String.trim_trailing(uri.path || "", "/") <> Responses.path()

    URI.to_string(%{uri | scheme: scheme, path: path})
  end

  defp create_event(body, stream_id) do
    body
    |> Map.delete("stream")
    |> Map.put("type", "response.create")
    |> Map.put("stream_id", stream_id)
  end

  defp encode(state, event) do
    case state.client.config.json.encode(event) do
      {:ok, json} when is_binary(json) -> {:ok, json}
      {:error, reason} -> {:error, transport(reason)}
      _other -> {:error, transport(:json_encoder_returned_invalid_value)}
    end
  end

  defp dispatch([], state), do: {:ok, state}

  defp dispatch([{:text, data} | rest], state) do
    case handle_text(data, state) do
      {:ok, state} -> dispatch(rest, state)
      {:error, reason, state} -> {:disconnect, reason, state}
    end
  end

  defp dispatch([{:binary, _data} | rest], state), do: dispatch(rest, state)

  defp dispatch([{:close, code, reason} | _rest], state),
    do: {:disconnect, {:closed, code, reason}, state}

  defp dispatch([_frame | rest], state), do: dispatch(rest, state)

  defp handle_text(data, state) do
    case state.client.config.json.decode(data) do
      {:ok, %{} = event} -> route_event(event, state)
      {:ok, _other} -> {:error, :non_object_event, state}
      {:error, reason} -> {:error, {:invalid_json, reason}, state}
    end
  end

  defp route_event(event, state) do
    case lane_for(event, state) do
      {:ok, stream_id, lane} -> decode_for_lane(event, stream_id, lane, state)
      :error when map_size(state.lanes) == 0 -> {:ok, state}
      :error -> {:error, :unroutable_event, state}
    end
  end

  defp lane_for(%{"stream_id" => stream_id}, state) when is_binary(stream_id) do
    case Map.fetch(state.lanes, stream_id) do
      {:ok, lane} -> {:ok, stream_id, lane}
      :error -> :error
    end
  end

  defp lane_for(_event, %{lanes: lanes}) when map_size(lanes) == 1 do
    [{stream_id, lane}] = Enum.to_list(lanes)
    {:ok, stream_id, lane}
  end

  defp lane_for(event, %{lanes: lanes}) do
    response_id = response_id(event)

    Enum.find_value(lanes, :error, fn {stream_id, lane} ->
      if is_binary(response_id) and lane.response_id == response_id,
        do: {:ok, stream_id, lane}
    end)
  end

  defp decode_for_lane(event, stream_id, lane, state) do
    response_id = response_id(event) || lane.response_id

    case Responses.decode_stream_event(event, state.client.config, lane.state) do
      {:ok, events, stream_state} ->
        send_events(lane, events)
        finished? = Enum.any?(events, &(&1.type == :message_stop))

        lane = %{lane | state: stream_state, response_id: response_id}
        state = %{state | lanes: Map.put(state.lanes, stream_id, lane)}

        if finished? do
          send(lane.subscriber, {:responses_ws, lane.ref, :done})
          state = remember_response(state, stream_id, response_id)
          {:ok, %{state | lanes: Map.delete(state.lanes, stream_id)}}
        else
          {:ok, state}
        end

      {:error, %Error{} = error} ->
        send(lane.subscriber, {:responses_ws, lane.ref, {:error, error}})
        state = remember_response(state, stream_id, response_id || lane.response_id)
        {:ok, %{state | lanes: Map.delete(state.lanes, stream_id)}}
    end
  end

  defp response_id(%{"response" => %{"id" => id}}) when is_binary(id), do: id
  defp response_id(_event), do: nil

  defp send_events(lane, events) do
    Enum.each(events, fn event ->
      send(lane.subscriber, {:responses_ws, lane.ref, {:event, event}})
    end)
  end

  defp do_reconnect(state, reason) do
    notify_lanes(state, interrupted(reason))
    state = %{state | lanes: %{}} |> cancel_max_age() |> cancel_retry()
    safe_close(state.ws, state.conn)

    case connect(state.client, state.ws, state.ws_opts) do
      {:ok, conn} -> {:ok, connected(%{state | conn: conn})}
      {:error, error} -> {:error, error, disconnected(%{state | conn: nil})}
    end
  end

  defp send_failure(state, reason) do
    notify_lanes(state, interrupted(reason))
    disconnected(%{state | lanes: %{}})
  end

  defp disconnect(state, reason) do
    notify_lanes(state, interrupted(reason))
    state = %{state | lanes: %{}}

    if state.reconnect? do
      {:noreply, disconnected(state)}
    else
      {:stop, {:shutdown, reason}, state}
    end
  end

  defp notify_lanes(state, error) do
    Enum.each(state.lanes, fn {_stream_id, lane} ->
      send(lane.subscriber, {:responses_ws, lane.ref, {:error, error}})
    end)
  end

  defp send_cancel(state, stream_id, response_id) do
    event =
      %{"type" => "response.cancel", "stream_id" => stream_id}
      |> maybe_put("response_id", response_id)

    case encode(state, event) do
      {:ok, json} ->
        case state.ws.send_frame(state.conn, {:text, json}) do
          {:ok, conn} -> %{state | conn: conn}
          {:error, _reason} -> state
        end

      {:error, _error} ->
        state
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp connected(state) do
    state = %{state | status: :connected, retry_attempts: 0}
    state = cancel_retry(state)
    schedule_max_age(state)
  end

  defp disconnected(state) do
    safe_close(state.ws, state.conn)
    state = %{state | status: :disconnected, conn: nil, lanes: %{}}
    state = cancel_max_age(state)

    if state.reconnect?, do: schedule_retry(state), else: state
  end

  defp remember_response(state, _stream_id, nil), do: state

  defp remember_response(state, stream_id, response_id) do
    finished = [{stream_id, response_id} | List.keydelete(state.finished, stream_id, 0)]
    %{state | finished: Enum.take(finished, 32)}
  end

  defp handle_max_age(%{reconnect?: false} = state) do
    {:stop, {:shutdown, :max_age}, state}
  end

  defp handle_max_age(state) do
    case do_reconnect(state, :max_age) do
      {:ok, state} -> {:noreply, state}
      {:error, _error, state} -> {:noreply, state}
    end
  end

  defp schedule_max_age(state) do
    state = cancel_max_age(state)
    ref = make_ref()
    timer = Process.send_after(self(), {:max_age, ref}, state.max_age)
    %{state | max_age_timer: timer, max_age_ref: ref}
  end

  defp schedule_retry(state) do
    attempts = state.retry_attempts + 1

    if retry_allowed?(state, attempts) do
      factor = Integer.pow(2, min(attempts - 1, 10))
      delay = min(state.retry_delay * factor, state.max_retry_delay)
      ref = make_ref()
      timer = Process.send_after(self(), {:retry, ref}, delay)
      %{state | retry_attempts: attempts, retry_timer: timer, retry_ref: ref}
    else
      %{state | retry_attempts: attempts, retry_timer: nil, retry_ref: nil}
    end
  end

  defp retry_allowed?(%{max_reconnect_attempts: :infinity}, _attempts), do: true

  defp retry_allowed?(state, attempts),
    do: attempts <= state.max_reconnect_attempts

  defp cancel_max_age(%{max_age_timer: nil} = state), do: state

  defp cancel_max_age(%{max_age_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | max_age_timer: nil, max_age_ref: nil}
  end

  defp cancel_retry(%{retry_timer: nil} = state), do: state

  defp cancel_retry(%{retry_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | retry_timer: nil, retry_ref: nil}
  end

  defp validate_stream_id(stream_id) when is_binary(stream_id) do
    if Regex.match?(@stream_id_pattern, stream_id),
      do: :ok,
      else: {:error, validation("stream_id must be 1-256 characters of [A-Za-z0-9_.-]")}
  end

  defp validate_stream_id(_stream_id),
    do: {:error, validation("stream_id must be a string")}

  defp validation(message), do: %Error{kind: :validation, message: message}

  defp transport(reason) do
    %Error{kind: :transport, message: "responses connection: #{inspect(reason)}"}
  end

  defp interrupted(reason) do
    %Error{
      kind: :transport,
      message: "responses connection: the in-flight response was interrupted (#{inspect(reason)})"
    }
  end

  defp safe_close(_ws, nil), do: :ok

  defp safe_close(ws, conn) do
    ws.close(conn, 1000, "connection closing")
  rescue
    _error -> :ok
  end

  defp disconnected_error do
    %Error{
      kind: :transport,
      message: "responses connection is disconnected; call reconnect/1 or retry later"
    }
  end

  defp safe_feed(ws, conn, message) do
    ws.feed(conn, message)
  rescue
    error -> {:error, {:feed_failed, error}}
  end
end
