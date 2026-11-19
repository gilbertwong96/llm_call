defmodule LlmCall.Application do
  @moduledoc """
  Starts the default Finch pool.

  The pool is named `LlmCall.Finch` so the one-call path needs no setup. A caller
  that wants its own pool starts it in its own supervision tree and passes
  `http_opts: [name: MyPool]` to a provider or client; the default pool stays
  unused in that case.

  If something is already registered as `LlmCall.Finch` when this application
  starts, no second pool is started: start your own pool before `:llm_call` (add
  it to `:extra_applications` or an earlier dependency) to own the name and its
  concurrency settings.
  """

  use Application

  @pool LlmCall.Finch

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(default_children(), strategy: :one_for_one, name: LlmCall.Supervisor)
  end

  @doc false
  @spec default_children() :: [{Finch, keyword()}]
  def default_children, do: default_children(@pool)

  @doc false
  @spec default_children(atom()) :: [{Finch, keyword()}]
  def default_children(pool) do
    if Process.whereis(pool), do: [], else: [{Finch, name: pool}]
  end
end
