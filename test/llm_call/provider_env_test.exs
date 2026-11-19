defmodule LlmCall.ProviderEnvTest do
  use ExUnit.Case, async: false

  alias LlmCall.Client

  defmodule DeclaringProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "https://api.example.test",
      auth: :none,
      http_opts: [pool_timeout: 1],
      timeout: 5_000,
      codecs: [chat: LlmCall.TestCodec.Fake]
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:llm_call, :http_opts)
      Application.delete_env(:llm_call, :timeout)
    end)

    :ok
  end

  test "config :llm_call, :http_opts applies when the provider declares none" do
    Application.put_env(:llm_call, :http_opts, pool_timeout: 999)

    assert %Client{http_opts: [pool_timeout: 999]} = LlmCall.TestProvider.client(api_key: "k")
  end

  test "a provider declaration wins over config :llm_call, :http_opts" do
    Application.put_env(:llm_call, :http_opts, pool_timeout: 999)

    assert %Client{http_opts: [pool_timeout: 1]} = DeclaringProvider.client([])
  end

  test "config :llm_call, :timeout applies when the provider declares none" do
    Application.put_env(:llm_call, :timeout, 12_345)

    assert %Client{timeout: 12_345} = LlmCall.TestProvider.client(api_key: "k")
  end

  test "a provider declaration wins over config :llm_call, :timeout" do
    Application.put_env(:llm_call, :timeout, 12_345)

    assert %Client{timeout: 5_000} = DeclaringProvider.client([])
  end

  test "the built-in defaults apply when nothing is configured" do
    assert %Client{http_opts: [], timeout: 60_000} = LlmCall.TestProvider.client(api_key: "k")
  end
end
