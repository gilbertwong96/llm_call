defmodule LlmCall.HTTP.Test do
  @moduledoc """
  Canned transport for tests: no socket, and it records the requests it received.

  Configure it per test process:

      LlmCall.HTTP.Test.put_response(%{status: 200, headers: [], body: "{}"})
      LlmCall.HTTP.Test.put_events([{:status, 200}, {:data, "data: ...\\n\\n"}])
  """

  @behaviour LlmCall.HTTP

  alias LlmCall.HTTP.Request

  @response_key :llm_call_http_test_response
  @events_key :llm_call_http_test_events
  @requests_key :llm_call_http_test_requests

  @doc "Sets the response `request/2` returns: `{:ok, response}` or `{:error, reason}`."
  def put_response(response), do: Process.put(@response_key, response)

  @doc "Sets the events `stream/4` delivers."
  def put_events(events), do: Process.put(@events_key, events)

  @doc "The requests received so far, oldest first."
  def requests, do: Process.get(@requests_key, []) |> Enum.reverse()

  @doc "Clears the recorded requests and any configured response or events."
  def reset do
    Process.delete(@response_key)
    Process.delete(@events_key)
    Process.delete(@requests_key)
    :ok
  end

  @impl true
  def request(%Request{} = request, _opts) do
    record(request)
    Process.get(@response_key, {:ok, %{status: 200, headers: [], body: "{}"}})
  end

  @impl true
  def stream(%Request{} = request, acc, fun, _opts) when is_function(fun, 2) do
    record(request)

    events = Process.get(@events_key, [])

    Enum.reduce_while(events, {:ok, acc}, fn event, {:ok, acc} ->
      case fun.(event, acc) do
        {:cont, acc} -> {:cont, {:ok, acc}}
        {:halt, acc} -> {:halt, {:ok, acc}}
      end
    end)
  end

  defp record(request), do: Process.put(@requests_key, [request | requests()])
end
