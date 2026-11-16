defmodule LlmDialect.Conformance do
  @moduledoc """
  Assertions shared by `LlmDialect.Codec.Conformance` and
  `LlmDialect.MediaConformance`.

  Test support, not a runtime dependency: it imports `ExUnit.Assertions` and is
  meant to be called from a test.
  """

  import ExUnit.Assertions

  alias LlmDialect.Codec

  @credential_headers ["authorization", "x-api-key", "api-key"]

  @doc """
  Asserts that `info/0` returns well-formed codec metadata.

  `ir_version` must be `1`; `version` is a wire version string or `nil`.
  """
  @spec assert_info(module()) :: :ok
  def assert_info(codec) do
    info = codec.info()

    assert %Codec.Info{name: name, protocol: protocol, version: version, ir_version: 1} = info,
           "#{inspect(codec)}.info/0 must return %LlmDialect.Codec.Info{} with ir_version 1"

    assert is_atom(name), "#{inspect(codec)}.info/0 name must be an atom"
    assert is_atom(protocol), "#{inspect(codec)}.info/0 protocol must be an atom"

    assert is_nil(version) or is_binary(version),
           "#{inspect(codec)}.info/0 version must be a string or nil"

    :ok
  end

  @doc "The header names a codec must never emit (the transport adds them)."
  @spec credential_headers() :: [String.t()]
  def credential_headers, do: @credential_headers
end
