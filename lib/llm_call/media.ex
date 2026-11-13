defmodule LlmCall.Media do
  @moduledoc """
  Namespace for the media adapters vendored with this library.

  The media **IR** — `LlmCall.Media.Request`, `LlmCall.Media.Response`,
  `LlmCall.Operation`, `LlmCall.Media.Capabilities`, and the
  `LlmCall.Media.Codec` behaviour — is the stable surface. The adapters under
  `LlmCall.Media.Protocol.*` are vendored implementations: they ship with the
  library, follow the same conformance suite as the reference chat adapters, and
  track provider APIs that change more often than the IR does.

  Vendored does not mean stable. A provider's API can change and force an adapter
  change in a minor release; the IR it maps into does not change with it. If the
  IR cannot express something an adapter needs, that is a core design discussion,
  not a local patch.
  """
end
