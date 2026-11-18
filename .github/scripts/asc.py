#!/usr/bin/env python3
"""App Store Connect helpers for the TestFlight workflow (installed by Dev_deploy_setup).

  asc.py next-build --bundle-id ID --version 1.2.0
      Print the next build number for that version. App Store Connect, not this repo, knows
      every build number it has accepted (including ones uploaded by hand from Xcode), so ask it.
      Prints 1 when the app or the version doesn't exist yet.

  asc.py ensure-app --bundle-id ID --name "My App"
      Register the bundle ID with the Apple Developer portal if it isn't registered yet, then
      report whether App Store Connect has an app record for it. Exit 0 when the app exists,
      3 when it doesn't (the API can't create app records; the workflow does that with fastlane
      when it has an Apple ID session, or asks you to make it by hand).

Authenticates with the API key in ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file).
Stdlib only: `openssl` signs the token and `urllib` makes the calls.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
APP_MISSING = 3


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_jose(der: bytes, size: int = 32) -> bytes:
    """ECDSA signature from DER (what openssl emits) to the raw r||s form JWS wants."""
    if not der or der[0] != 0x30:
        raise ValueError("signature is not a DER sequence")
    i = 2 + (der[1] & 0x7F) if der[1] & 0x80 else 2
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("expected a DER integer in the signature")
        length = der[i + 1]
        value = der[i + 2 : i + 2 + length].lstrip(b"\x00")
        out += value.rjust(size, b"\x00")
        i += 2 + length
    return out


def make_token() -> str:
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = "{}.{}".format(
        b64u(json.dumps(header, separators=(",", ":")).encode()),
        b64u(json.dumps(payload, separators=(",", ":")).encode()),
    )
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
        input=signing_input.encode(), capture_output=True,
    )
    if result.returncode != 0:
        sys.exit("openssl could not sign the token: " + result.stderr.decode().strip())
    return "{}.{}".format(signing_input, b64u(der_to_jose(result.stdout)))


def call(method: str, path: str, token: str, body=None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        API + path, data=data, method=method,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:400]
        sys.exit("App Store Connect returned {} for {} {}\n{}".format(error.code, method, path, detail))


def find_app(bundle_id: str, token: str):
    apps = call("GET", "/apps?filter[bundleId]={}&limit=1".format(urllib.parse.quote(bundle_id)), token)
    return apps["data"][0] if apps.get("data") else None


def next_build(args) -> int:
    token = make_token()
    app = find_app(args.bundle_id, token)
    if not app:
        print("No app for {} yet: starting at 1".format(args.bundle_id), file=sys.stderr)
        print(1)
        return 0
    builds = call("GET", "/builds?filter[app]={}&filter[preReleaseVersion.version]={}&limit=200".format(
        app["id"], urllib.parse.quote(args.version)), token)
    # Build numbers are strings; skip ones that aren't whole numbers rather than guess.
    seen = [int(v) for v in ((b.get("attributes") or {}).get("version") or "" for b in builds.get("data", []))
            if v.isdigit()]
    highest = max(seen) if seen else 0
    print("Version {}: highest existing build is {}".format(args.version, highest or "none"), file=sys.stderr)
    print(highest + 1)
    return 0


def ensure_app(args) -> int:
    token = make_token()
    found = call("GET", "/bundleIds?filter[identifier]={}&limit=200".format(urllib.parse.quote(args.bundle_id)), token)
    # The filter is a prefix match, so check for the exact identifier.
    if any((b.get("attributes") or {}).get("identifier") == args.bundle_id for b in found.get("data", [])):
        print("Bundle ID {} is registered".format(args.bundle_id), file=sys.stderr)
    else:
        name = re.sub(r"[^A-Za-z0-9 ]", " ", args.name).strip() or "App"
        call("POST", "/bundleIds", token, {"data": {"type": "bundleIds", "attributes": {
            "identifier": args.bundle_id, "name": name, "platform": "IOS"}}})
        print("Registered bundle ID {}".format(args.bundle_id), file=sys.stderr)
    if find_app(args.bundle_id, token):
        print("App Store Connect has an app for {}".format(args.bundle_id), file=sys.stderr)
        return 0
    print("App Store Connect has no app for {}".format(args.bundle_id), file=sys.stderr)
    return APP_MISSING


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("next-build")
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(func=next_build)
    p = sub.add_parser("ensure-app")
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--name", required=True)
    p.set_defaults(func=ensure_app)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
