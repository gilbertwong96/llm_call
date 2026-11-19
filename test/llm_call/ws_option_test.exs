defmodule LlmCall.WSOptionTest do
  use ExUnit.Case, async: true

  alias LlmCall.TestWSServer, as: Server
  alias LlmCall.WS.Mint

  setup do
    Server.start()
    on_exit(&Server.stop/0)
    :ok
  end

  test "rejects a non-active socket mode instead of waiting for a timeout" do
    for mode <- [:passive, :bogus] do
      assert {:error, {:unsupported_mode, ^mode}} =
               Mint.connect(Server.url(), [], timeout: 2_000, mode: mode)
    end
  end

  test "accepts an explicit active mode" do
    assert {:ok, conn} = Mint.connect(Server.url(), [], timeout: 2_000, mode: :active)
    assert {:ok, conn} = Mint.send_frame(conn, {:text, "hello"})
    assert {:ok, {:text, "hello"}, conn} = Mint.recv(conn, 2_000)
    Mint.close(conn)
  end
end
