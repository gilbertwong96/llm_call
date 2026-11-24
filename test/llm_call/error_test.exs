defmodule LlmCall.ErrorTest do
  use ExUnit.Case, async: true

  alias LlmCall.Error

  describe "from_transport/1" do
    test "a connection-level failure is worth another attempt" do
      for reason <- [
            :timeout,
            :closed,
            :econnrefused,
            :econnreset,
            :etimedout,
            :epipe,
            :ehostunreach,
            :enetunreach,
            :nxdomain,
            {:tls_alert, :handshake_failure},
            {:interrupted, :reconnected},
            {:interrupted, :max_age}
          ] do
        assert %Error{kind: :transport, reason: ^reason, retryable?: true} =
                 Error.from_transport(reason)
      end
    end

    test "a failure another attempt cannot fix is not" do
      for reason <- [
            {:unknown_pool, :pool},
            {:interrupted, {:unroutable_event, :stream_id_not_echoed}},
            {:exception, "boom"},
            :programming_error
          ] do
        assert %Error{kind: :transport, retryable?: false} = Error.from_transport(reason)
      end
    end

    test "the reason is normalized out of the transport struct" do
      assert %Error{reason: :timeout} =
               Error.from_transport(%Finch.TransportError{reason: :timeout})
    end
  end
end
