defmodule LlmCall.Capabilities.InputTest do
  use ExUnit.Case, async: true

  alias LlmCall.Capabilities
  alias LlmCall.Capabilities.Input

  test "the default accepts nothing, which is what false meant before" do
    assert Input.kinds(%Input{}) == []

    assert %Input{inline: false, url: false, file: false} = %Capabilities{}.image_input
    assert %Input{inline: false, url: false, file: false} = %Capabilities{}.file_input
  end

  test "kinds are listed in canonical order, not declaration order" do
    assert Input.kinds(%Input{file: true, inline: true}) == [:inline, :file]
    assert Input.kinds(%Input{url: true, file: true, inline: true}) == [:inline, :url, :file]
  end

  test "each canonical source maps to exactly one kind" do
    assert Input.kind({:base64, "AA=="}) == :inline
    assert Input.kind({:url, "https://example.test/i.png"}) == :url
    assert Input.kind({:file_id, "file-abc"}) == :file
  end

  # The bare string is the shorthand the HTTP codecs already read as a URL, so it must
  # not be a fourth kind: it is the same question as `{:url, _}`.
  test "a bare string is a url" do
    assert Input.kind("https://example.test/i.png") == :url
    assert Input.accepts?(%Input{url: true}, "https://example.test/i.png")
  end

  test "accepts? answers per source, not per part" do
    inline_only = %Input{inline: true}

    assert Input.accepts?(inline_only, {:base64, "AA=="})
    refute Input.accepts?(inline_only, {:url, "https://example.test/i.png"})
    refute Input.accepts?(inline_only, {:file_id, "file-abc"})
  end
end
