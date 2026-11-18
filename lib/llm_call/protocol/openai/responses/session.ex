defmodule LlmCall.Protocol.OpenAI.Responses.Session do
  @moduledoc """
  A WebSocket session for OpenAI Responses (`wss://…/v1/responses`).

  The session owns one `LlmCall.WS` connection and multiplexes `response.create`
  calls over it. Each call names a `stream_id` lane (generated when omitted);
  events are decoded per lane by `LlmCall.Protocol.OpenAI.Responses` and
  delivered to the `%Stream{}` returned by `create/3`.

  `previous_response_id`, `store` and `include` belong in the request's
  `provider_options`, exactly as on HTTP. `steer/3` sends `response.steer` for an
  active lane; `cancel/2` sends `response.cancel` and ends the lane.

  ## Reconnect

  A Responses WebSocket may live for at most 60 minutes. The session reconnects
  before that (`:max_age_ms`, default 55 minutes) and on an unexpected close.
  An in-flight lane cannot be resumed: its subscriber receives a `:transport`
  error, and new `create/3` calls work on the new connection. Continuing a
  conversation across a reconnect is the caller's decision, using
  `previous_response_id` and the input it wants to resend.
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
  """
  @spec create(t(), LlmCall.Request.t(), keyword()) ::
          {:ok, LlmCall.Protocol.OpenAI.Responses.Stream.t()} | {:error, Error.t()}
  def create(session, request, opts \\ []) do
    GenServer.call(session, {:create, request, opts}, @default_timeout)
  end

  @doc """
  Queues `input` for the active response on `stream_id` with `response.steer`.

  `input` is wire-shaped (a string or a list of Responses input items); the
  session does not reinterpret it.
  """
  @spec steer(t(), String.t(), term()) :: :ok | {:error, Error.t()}
  def steer(session, stream_id, input) do
    GenServer.call(session, {:steer, stream_id, input}, @default_timeout)
  end

  @doc "Cancels the lane's active response and ends it."
  @spec cancel(t(), String.t()) :: :ok | {:error, Error.t()}
  def cancel(session, stream_id) do
    GenServer.call(session, {:cancel, stream_id}, @default_timeout)
  end

  @doc """
  Reconnects now. In-flight lanes receive a `:transport` error; idle lanes are
  unaffected because there are none.
  """
  @spec reconnect(t()) :: :ok | {:error, Error.t()}
  def reconnect(session), do: GenServer.call(session, :reconnect, @default_timeout)

  @doc "Closes the connection and stops the session."
  @spec close(t()) :: :ok
  def close(session), do: GenServer.stop(session, :normal)

  @impl true
  def init(opts) do
    client = Keyword.get(opts, :client)
    ws = Keyword.get(opts, :ws, WS.Mint)
    ws_opts = Keyword.get(opts, :ws_opts, [])
    max_age = Keyword.get(opts, :max_age_ms, @default_max_age)
    reconnect? = Keyword.get(opts, :reconnect, true)

    cond do
      not match?(%Client{}, client) ->
        {:stop, :client_required}

      not is_integer(max_age) or max_age <= 0 ->
        {:stop, :invalid_max_age}

      true ->
        case connect(client, ws, ws_opts) do
          {:ok, conn} ->
            {:ok,
             schedule(%{
               client: client,
               ws: ws,
               ws_opts: ws_opts,
               conn: conn,
               max_age: max_age,
               reconnect?: reconnect?,
               timer: nil,
               lanes: %{}
             })}

          {:error, reason} ->
            {:stop, {:connect_failed, reason}}
        end
    end
  end

  @impl true
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

      stream = %LlmCall.Protocol.OpenAI.Responses.Stream{
        session: self(),
        stream_id: stream_id,
        ref: ref
      }

      state = %{state | conn: conn, lanes: Map.put(state.lanes, stream_id, lane)}
      {:reply, {:ok, stream}, state}
    else
      true ->
        {:reply, {:error, validation("stream_id #{inspect(stream_id)} is already in use")}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:error, reason} ->
        {:reply, {:error, transport(reason)}, state}
    end
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
        {:reply, {:error, transport(reason)}, state}
    end
  end

  def handle_call({:cancel, stream_id}, _from, state) do
    case Map.fetch(state.lanes, stream_id) do
      {:ok, lane} ->
        state = send_cancel(state, stream_id, lane.response_id)
        send(lane.subscriber, {:responses_ws, lane.ref, :done})
        {:reply, :ok, %{state | lanes: Map.delete(state.lanes, stream_id)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:reconnect, _from, state) do
    case do_reconnect(state, :reconnected) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, transport(reason)}, state}
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
  def handle_info(:reconnect, state) do
    case do_reconnect(state, :max_age) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, {:shutdown, reason}, state}
    end
  end

  def handle_info(message, state) when is_tuple(message) do
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

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state)
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
      :error -> {:ok, state}
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

  defp lane_for(_event, _state), do: :error

  defp decode_for_lane(event, stream_id, lane, state) do
    response_id = get_in(event, ["response", "id"]) || lane.response_id

    case Responses.decode_stream_event(event, state.client.config, lane.state) do
      {:ok, events, stream_state} ->
        send_events(lane, events)
        finished? = Enum.any?(events, &(&1.type == :message_stop))

        lane = %{lane | state: stream_state, response_id: response_id}
        state = %{state | lanes: Map.put(state.lanes, stream_id, lane)}

        if finished? do
          send(lane.subscriber, {:responses_ws, lane.ref, :done})
          {:ok, %{state | lanes: Map.delete(state.lanes, stream_id)}}
        else
          {:ok, state}
        end

      {:error, %Error{} = error} ->
        send(lane.subscriber, {:responses_ws, lane.ref, {:error, error}})
        {:ok, %{state | lanes: Map.delete(state.lanes, stream_id)}}
    end
  end

  defp send_events(lane, events) do
    Enum.each(events, fn event ->
      send(lane.subscriber, {:responses_ws, lane.ref, {:event, event}})
    end)
  end

  defp do_reconnect(state, reason) do
    notify_lanes(state, interrupted(reason))
    cancel_timer(state)
    safe_close(state.ws, state.conn)

    case connect(state.client, state.ws, state.ws_opts) do
      {:ok, conn} -> {:ok, schedule(%{state | conn: conn, lanes: %{}})}
      {:error, error} -> {:error, error}
    end
  end

  defp disconnect(state, reason) do
    if state.reconnect? do
      case do_reconnect(state, reason) do
        {:ok, state} -> {:noreply, state}
        {:error, error} -> {:stop, {:shutdown, error}, state}
      end
    else
      notify_lanes(state, interrupted(reason))
      {:stop, {:shutdown, reason}, %{state | lanes: %{}}}
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

  defp schedule(state) do
    %{state | timer: Process.send_after(self(), :reconnect, state.max_age)}
  end

  defp cancel_timer(%{timer: nil}), do: :ok

  defp cancel_timer(%{timer: timer}) do
    Process.cancel_timer(timer)
    :ok
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
    %Error{kind: :transport, message: "responses session: #{inspect(reason)}"}
  end

  defp interrupted(reason) do
    %Error{
      kind: :transport,
      message: "responses session: the in-flight response was interrupted (#{inspect(reason)})"
    }
  end

  defp safe_close(ws, conn) do
    ws.close(conn, 1000, "session closing")
  rescue
    _error -> :ok
  end

  defp safe_feed(ws, conn, message) do
    ws.feed(conn, message)
  rescue
    error -> {:error, {:feed_failed, error}}
  end
end
