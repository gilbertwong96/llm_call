defmodule LlmCall.Application do
  @moduledoc """
  Starts the default Finch pool.

  The pool is named `LlmCall.Finch` and is always started, so the one-call path
  needs no setup. A caller that wants its own pool starts it in its own
  supervision tree and passes `http_opts: [name: MyPool]` to a provider or client;
  the default pool stays unused in that case.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: LlmCall.Finch}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LlmCall.Supervisor)
  end
end
