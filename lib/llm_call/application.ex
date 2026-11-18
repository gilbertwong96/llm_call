defmodule LlmCall.Application do
  @moduledoc """
  Starts the default Finch pool.

  The pool is named `LlmCall.Finch`. A caller that wants its own pool starts it in
  its own supervision tree and passes `http_opts: [name: MyPool]` to a provider or
  client; the library never starts a pool it was not asked for.
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
