// Regenerates the frames in ../eventstream.ex.
//
// The oracle is @smithy/eventstream-codec, the encoder the AWS SDK for JavaScript
// uses to talk to Bedrock. It is not a dependency of this library: it exists so the
// bytes the Elixir decoder is tested against were produced by an independent
// implementation. A hand-written fixture would only confirm what we already believed,
// and a wrong header length or CRC would be wrong in both encoder and decoder.
//
//   npm install @smithy/eventstream-codec@4.5.2
//   node generate.mjs
//
// Paste the JSON into `@frames` in ../eventstream.ex. Changing a header set here means
// regenerating, never editing the base64 by hand.
import { EventStreamCodec, Int64 } from "@smithy/eventstream-codec";

// The codec's two callbacks look inverted: `fromUtf8` is the one that produces bytes.
const codec = new EventStreamCodec(
  (bytes) => Buffer.from(bytes).toString("utf8"),
  (text) => Buffer.from(text, "utf8"),
);

const str = (value) => ({ type: "string", value });

const cases = {
  // The first Converse event.
  message_start: [
    [
      [":message-type", str("event")],
      [":event-type", str("messageStart")],
      [":content-type", str("application/json")],
    ],
    Buffer.from('{"role":"assistant"}', "utf8"),
  ],
  // A content block delta, the hot path.
  content_block_delta: [
    [
      [":message-type", str("event")],
      [":event-type", str("contentBlockDelta")],
      [":content-type", str("application/json")],
    ],
    Buffer.from('{"delta":{"text":"Hello"},"contentBlockIndex":0}', "utf8"),
  ],
  // Bedrock reports a throttled stream as a frame, not as an HTTP status.
  exception: [
    [
      [":message-type", str("exception")],
      [":exception-type", str("throttlingException")],
      [":content-type", str("application/json")],
    ],
    Buffer.from('{"message":"Too many requests"}', "utf8"),
  ],
  // 16 bytes: no headers, no payload.
  empty: [[], Buffer.from("", "utf8")],
  // One of every header value type, so the decoder's width arithmetic is exercised.
  every_header_type: [
    [
      ["bool_true", { type: "boolean", value: true }],
      ["bool_false", { type: "boolean", value: false }],
      ["byte", { type: "byte", value: -7 }],
      ["short", { type: "short", value: -300 }],
      ["integer", { type: "integer", value: -70000 }],
      ["long", { type: "long", value: Int64.fromNumber(1234567890123) }],
      ["binary", { type: "binary", value: Uint8Array.from([0x00, 0xff, 0x7f]) }],
      ["string", str("héllo")],
      ["timestamp", { type: "timestamp", value: new Date(1700000000000) }],
      ["uuid", { type: "uuid", value: "01234567-89ab-cdef-0123-456789abcdef" }],
    ],
    Buffer.from("payload", "utf8"),
  ],
  // The payload is bytes, not text.
  binary_payload: [
    [[":event-type", str("blob")]],
    Buffer.from([0x00, 0xff, 0xfe, 0x80]),
  ],
};

const out = {};
for (const [name, [headers, body]] of Object.entries(cases)) {
  const headerMap = {};
  for (const [headerName, value] of headers) headerMap[headerName] = value;
  out[name] = Buffer.from(codec.encode({ headers: headerMap, body })).toString("base64");
}

// A frame cut in two, at a prelude boundary: the remainder must survive in the buffer
// and complete on the next chunk.
const whole = Buffer.from(
  codec.encode({
    headers: {
      ":event-type": str("contentBlockDelta"),
      ":content-type": str("application/json"),
    },
    body: Buffer.from('{"delta":{"text":"split"}}', "utf8"),
  }),
);
out.split_first_half = whole.subarray(0, 9).toString("base64");
out.split_second_half = whole.subarray(9).toString("base64");

console.log(JSON.stringify(out, null, 2));
