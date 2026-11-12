defmodule LlmCall.Codec.Info do
  @moduledoc """
  Codec metadata.

  `protocol` names the wire family, `version` the wire version the codec targets,
  and `ir_version` the canonical IR contract it was implemented against.
  """

  @type t :: %__MODULE__{
          name: atom(),
          protocol: atom(),
          version: String.t() | nil,
          ir_version: pos_integer()
        }

  defstruct [:name, :protocol, :version, :ir_version]
end
