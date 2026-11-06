#!/usr/bin/env python3
"""Signing assets for Driftwood without Xcode's own sign-in (Xcode 27.1 on GitHub's runner
answers "Authentication failed" with an API key that works for every API call).

Through the App Store Connect API (asc.py's token), for each target's bundle ID:
  - registers it if it isn't, and turns on App Groups;
  - creates an App Store profile for the distribution certificate with the given serial,
    installs it where Xcode looks, and checks it carries the app group.
Prints one JSON object: {"<bundle id>": "<profile name>", ...}

  manual_signing.py --bundle-id com.lightwave.driftwood --certificate-serial 1A2B...
Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH, like asc.py.
"""

import argparse
import base64
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc  # noqa: E402

# Suffix → readable name, for each target that ships in the archive
TARGETS = {
    "": "Driftwood",
    ".watchkitapp": "Driftwood Watch",
    ".watchkitapp.widgets": "Driftwood Watch Widgets",
    ".BookPlayerWidgetUI": "Driftwood Widgets",
    ".BookPlayerShareExtension": "Driftwood Share",
}

PROFILE_FOLDERS = [
    os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
    os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
]


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def request(method: str, path: str, token: str, body=None):
    """(status, decoded body); never exits, unlike asc.call"""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        asc.API + path, data=data, method=method,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as error:
        raw = error.read().decode(errors="replace")
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {"raw": raw[:300]}


def error_text(body) -> str:
    errors = body.get("errors") if isinstance(body, dict) else None
    if errors:
        return "; ".join(e.get("detail") or e.get("title") or "" for e in errors)
    return str(body)[:300]


def find_bundle_id(identifier: str, token: str):
    status, body = request("GET", "/bundleIds?filter[identifier]={}&limit=20".format(urllib.parse.quote(identifier)), token)
    if status != 200:
        sys.exit("Couldn't look up {}: {}".format(identifier, error_text(body)))
    # filter[identifier] also matches prefixes: take the exact one
    for item in body.get("data", []):
        if item["attributes"]["identifier"] == identifier:
            return item
    return None


def ensure_bundle_id(identifier: str, name: str, token: str) -> str:
    item = find_bundle_id(identifier, token)
    if item:
        log("App ID {} is registered".format(identifier))
        return item["id"]

    status, body = request("POST", "/bundleIds", token, {"data": {"type": "bundleIds", "attributes": {
        "identifier": identifier, "name": name, "platform": "IOS"}}})
    if status not in (200, 201):
        sys.exit("Couldn't register {}: {}".format(identifier, error_text(body)))
    log("Registered App ID {}".format(identifier))
    return body["data"]["id"]


def ensure_app_groups(bundle_resource_id: str, identifier: str, token: str) -> None:
    status, body = request("GET", "/bundleIds/{}/bundleIdCapabilities?limit=50".format(bundle_resource_id), token)
    if status == 200 and any(c["attributes"].get("capabilityType") == "APP_GROUPS" for c in body.get("data", [])):
        return
    status, body = request("POST", "/bundleIdCapabilities", token, {"data": {
        "type": "bundleIdCapabilities",
        "attributes": {"capabilityType": "APP_GROUPS"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}}},
    }})
    if status not in (200, 201, 409):
        sys.exit("Couldn't turn on App Groups for {}: {}".format(identifier, error_text(body)))
    log("Turned on App Groups for {}".format(identifier))


def find_certificate(serial: str, token: str) -> str:
    wanted = serial.upper().lstrip("0")
    status, body = request("GET", "/certificates?limit=200", token)
    if status != 200:
        sys.exit("Couldn't list certificates: {}".format(error_text(body)))
    for item in body.get("data", []):
        if (item["attributes"].get("serialNumber") or "").upper().lstrip("0") == wanted:
            return item["id"]
    sys.exit("The distribution certificate (serial {}) isn't in this team's certificates".format(serial))


def profile_entitlements(content: bytes) -> dict:
    decoded = subprocess.run(["security", "cms", "-D"], input=content, capture_output=True)
    if decoded.returncode != 0:
        return {}
    return plistlib.loads(decoded.stdout).get("Entitlements", {})


def create_profile(identifier: str, name: str, bundle_resource_id: str, certificate_id: str, token: str):
    profile_name = "{} App Store {}".format(name, time.strftime("%Y%m%d%H%M%S"))
    status, body = request("POST", "/profiles", token, {"data": {
        "type": "profiles",
        "attributes": {"name": profile_name, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}},
            "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
        },
    }})
    if status not in (200, 201):
        sys.exit("Couldn't create a profile for {}: {}".format(identifier, error_text(body)))

    attributes = body["data"]["attributes"]
    content = base64.b64decode(attributes["profileContent"])
    for folder in PROFILE_FOLDERS:
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, attributes["uuid"] + ".mobileprovision"), "wb") as handle:
            handle.write(content)

    return profile_name, content


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--certificate-serial", required=True)
    args = parser.parse_args()

    token = asc.make_token()
    certificate_id = find_certificate(args.certificate_serial, token)
    group = "group.{}".format(args.bundle_id)

    profiles = {}
    missing_group = []
    for suffix, name in TARGETS.items():
        identifier = args.bundle_id + suffix
        resource_id = ensure_bundle_id(identifier, name, token)
        ensure_app_groups(resource_id, identifier, token)
        profile_name, content = create_profile(identifier, name, resource_id, certificate_id, token)
        groups = profile_entitlements(content).get("com.apple.security.application-groups", [])
        if group not in groups:
            missing_group.append(identifier)
        profiles[identifier] = profile_name
        log("Profile for {}: {}".format(identifier, profile_name))

    if missing_group:
        print("::error::App group {} isn't assigned to: {}. In developer.apple.com → Identifiers, open each, "
              "App Groups → Configure, tick {} and Save, then build again.".format(
                  group, ", ".join(missing_group), group), file=sys.stderr)
        return 2

    print(json.dumps(profiles))
    return 0


if __name__ == "__main__":
    sys.exit(main())
