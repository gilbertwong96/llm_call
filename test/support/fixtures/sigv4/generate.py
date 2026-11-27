#!/usr/bin/env python3
# Regenerates the vectors in ../sigv4.ex.
#
# The oracle is botocore's SigV4Auth — the canonical-request implementation the AWS
# SDK for Python uses, and therefore the one the service must agree with. It is not a
# dependency of this library: it exists so the signature this library produces for a
# request shape is somebody else's, not ours.
#
#   python3 -m venv .venv && .venv/bin/pip install botocore==1.44.12
#   .venv/bin/python generate.py
#
# Paste the JSON into `@vectors` in ../sigv4.ex. The timestamp is not frozen in this
# script: botocore stamps the current time, so the vector records the `amz_date` it
# used and the test signs with that same instant. Changing a case here means
# regenerating, never editing a signature by hand.
import json
from urllib.parse import quote, urlencode

from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials

STATIC = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
SESSION = Credentials(
    "TESTIOSFODNN7EXAMPLE",
    "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    "AQoDYXdzEJr+EXAMPLE-TOKEN",
)

BEDROCK = "https://bedrock-runtime.us-east-1.amazonaws.com"

CASES = [
    # A model id whose colon a codec has already written as %3A. The canonical URI
    # encodes the % again, which is the rule the published ListUsers vector cannot
    # show: its path is "/".
    {
        "name": "converse_colon_encoded",
        "method": "POST",
        "url": BEDROCK + "/model/anthropic.claude-3-5-sonnet-20241022-v2%3A0/converse",
        "headers": {"content-type": "application/json"},
        "body": '{"messages":[]}',
        "service": "bedrock",
        "region": "us-east-1",
        "credentials": "static",
    },
    # An inference-profile ARN is one path segment, so its slashes are encoded too.
    {
        "name": "converse_arn_model",
        "method": "POST",
        "url": BEDROCK
        + "/model/arn%3Aaws%3Abedrock%3Aus-east-1%3A123456789012%3Ainference-profile%2Fus.anthropic.claude-3-5-sonnet-20241022-v2%3A0/converse",
        "headers": {"content-type": "application/json"},
        "body": '{"messages":[]}',
        "service": "bedrock",
        "region": "us-east-1",
        "credentials": "static",
    },
    # Unreserved characters stay as they are; nothing to encode, so this one pins that
    # the encoder does not over-encode.
    {
        "name": "path_unreserved",
        "method": "POST",
        "url": BEDROCK + "/model/a-b_c.d~e/converse",
        "headers": {"content-type": "application/json"},
        "body": "{}",
        "service": "bedrock",
        "region": "us-east-1",
        "credentials": "static",
    },
    # A GET with no body: the payload hash is the hash of the empty string.
    {
        "name": "get_empty_body",
        "method": "GET",
        "url": "https://iam.amazonaws.com/",
        "headers": {},
        "body": None,
        "service": "iam",
        "region": "us-east-1",
        "credentials": "static",
    },
    # Query canonicalisation: encoding before sorting, a space, a tilde, and a key
    # whose encoded form sorts differently from its raw form.
    {
        "name": "query_encoding_and_order",
        "method": "GET",
        "url": "https://iam.amazonaws.com/",
        "headers": {},
        "body": "",
        "query": {
            "Action": "ListUsers",
            "Version": "2010-05-08",
            "PathPrefix": "/a b~/c",
            "Zed": "1",
            "a": "2",
        },
        "service": "iam",
        "region": "us-east-1",
        "credentials": "static",
    },
    # Temporary credentials: the token is sent and signed, so it appears in
    # SignedHeaders after x-amz-date.
    {
        "name": "session_token",
        "method": "POST",
        "url": BEDROCK + "/model/anthropic.claude-3-5-sonnet-20241022-v2%3A0/converse",
        "headers": {"content-type": "application/json"},
        "body": '{"messages":[]}',
        "service": "bedrock",
        "region": "us-east-1",
        "credentials": "session",
    },
    # A header value with a tab and doubled spaces: SigV4 signs the trimmed,
    # collapsed form, not the bytes on the wire.
    {
        "name": "header_value_normalised",
        "method": "POST",
        "url": BEDROCK + "/model/m/converse",
        "headers": {"content-type": "application/json", "x-amz-custom": "  a\t b  "},
        "body": "{}",
        "service": "bedrock",
        "region": "us-east-1",
        "credentials": "static",
    },
    # A body that is not ASCII: the payload hash covers the UTF-8 bytes.
    {
        "name": "utf8_body",
        "method": "POST",
        "url": BEDROCK + "/model/m/converse",
        "headers": {"content-type": "application/json"},
        "body": '{"text":"héllo"}',
        "service": "bedrock",
        "region": "eu-west-1",
        "credentials": "static",
    },
]


def sign(case):
    creds = SESSION if case["credentials"] == "session" else STATIC
    auth = SigV4Auth(creds, case["service"], case["region"])
    url = case["url"]
    if case.get("query"):
        # The query has to be on the URL: botocore parses it, decodes it, and re-encodes
        # it for the canonical form, which is the same normalisation this library does
        # from its own map.
        url = url + "?" + urlencode(sorted(case["query"].items()), quote_via=quote, safe="")
    req = AWSRequest(method=case["method"], url=url, data=case.get("body"), headers=case["headers"])
    # Before add_auth: afterwards botocore's own Authorization header is part of the
    # request and would appear in the canonical headers of a second call.
    canonical_request = auth.canonical_request(req)
    auth.add_auth(req)
    return {
        "name": case["name"],
        "method": case["method"],
        "url": url,
        "headers": case["headers"],
        "body": case.get("body"),
        "query": case.get("query", {}),
        "service": case["service"],
        "region": case["region"],
        "credentials": case["credentials"],
        "amz_date": req.headers["X-Amz-Date"],
        "canonical_request": canonical_request,
        "authorization": req.headers["Authorization"],
    }


out = [sign(case) for case in CASES]
print(json.dumps(out, indent=2, ensure_ascii=False))
