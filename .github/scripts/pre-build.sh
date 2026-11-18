#!/bin/bash
# Run by the iOS TestFlight workflow before the archive, in the repository root.
# Writes the two git-ignored xcconfig files for the Driftwood personal build: your team, the
# Driftwood bundle ID, and placeholders for BookPlayer's own services (RevenueCat, Sentry, the
# BookPlayer server), which this build doesn't use.
set -euo pipefail

# BookPlayer needs Xcode 27.1 (iOS 27.1 SDK APIs); the workflow picks the newest Xcode, so pin it
if [ -d /Applications/Xcode_27.1.app ]; then
  sudo xcode-select -s /Applications/Xcode_27.1.app/Contents/Developer
fi
xcodebuild -version

# Xcode reads the App Store Connect key more strictly than openssl (which asc.py uses): strip
# carriage returns and rewrite it as standard PKCS#8 PEM. Prints only its shape, never the key.
if [ -n "${ASC_KEY_PATH:-}" ] && [ -f "$ASC_KEY_PATH" ]; then
  tr -d '\r' < "$ASC_KEY_PATH" > "$ASC_KEY_PATH.clean"
  if openssl pkey -in "$ASC_KEY_PATH.clean" -out "$ASC_KEY_PATH.pem" 2>/dev/null; then
    mv "$ASC_KEY_PATH.pem" "$ASC_KEY_PATH"
  else
    mv "$ASC_KEY_PATH.clean" "$ASC_KEY_PATH"
  fi
  rm -f "$ASC_KEY_PATH.clean" "$ASC_KEY_PATH.pem"
  chmod 600 "$ASC_KEY_PATH"
  echo "API key file: $(head -1 "$ASC_KEY_PATH"), $(wc -l < "$ASC_KEY_PATH") lines"
fi
for name in ASC_KEY_ID ASC_ISSUER_ID; do
  value="${!name:-}"
  if [ "$value" != "$(printf '%s' "$value" | tr -d '[:space:]')" ]; then
    echo "::warning::$name has whitespace in it"
  fi
done

team=$(jq -r '.APPLE_TEAM_ID // empty' <<<"$SECRETS_JSON")
if [ -z "$team" ]; then echo "::error::APPLE_TEAM_ID secret is missing"; exit 1; fi
bundle_id="${BUNDLE_ID:-com.lightwave.driftwood}"

# Xcode signs in to the team it's given: if that isn't the API key's team, it fails with
# "Authentication failed". The key's own team is the seed ID App Store Connect gives a bundle ID.
key_team=$(python3 - "$bundle_id" <<'PY' 2>/dev/null || true
import os, sys, urllib.parse
sys.path.insert(0, os.path.join(os.environ["GITHUB_WORKSPACE"], ".github", "scripts"))
import asc
token = asc.make_token()
found = asc.call("GET", "/bundleIds?filter[identifier]=" + urllib.parse.quote(sys.argv[1]) + "&limit=1", token)
print(found["data"][0]["attributes"]["seedId"] if found.get("data") else "")
PY
)
if [ -n "$key_team" ] && [ "$key_team" != "$team" ]; then
  echo "::warning::APPLE_TEAM_ID isn't the App Store Connect key's team; signing with the key's team instead"
  team="$key_team"
elif [ -n "$key_team" ]; then
  echo "APPLE_TEAM_ID matches the App Store Connect key's team"
else
  echo "::warning::Couldn't read the App Store Connect key's team"
fi
# The workflow passes $TEAM_ID to Xcode: point it at the team that will sign
echo "TEAM_ID=$team" >> "$GITHUB_ENV"

# What this key may do in Certificates, Identifiers & Profiles, which Xcode's automatic signing
# needs (prints only HTTP outcomes)
python3 - <<'PY' || true
import os, sys
sys.path.insert(0, os.path.join(os.environ["GITHUB_WORKSPACE"], ".github", "scripts"))
import asc
token = asc.make_token()
for path in ["/certificates?limit=1", "/profiles?limit=1", "/devices?limit=1", "/bundleIds?limit=1"]:
    try:
        result = asc.call("GET", path, token)
        print("Key check", path.split("?")[0], "OK,", len(result.get("data", [])), "item(s)")
    except SystemExit as error:
        print("Key check", path.split("?")[0], "FAILED:", str(error).splitlines()[0])
PY

# Some Xcode versions only find an API key in these folders
for folder in "$HOME/.appstoreconnect/private_keys" "$HOME/private_keys"; do
  mkdir -p "$folder"
  cp "$ASC_KEY_PATH" "$folder/AuthKey_${ASC_KEY_ID}.p8"
  chmod 600 "$folder/AuthKey_${ASC_KEY_ID}.p8"
done
hardcover=$(jq -r '.BP_HARDCOVER_CLIENT_ID // empty' <<<"$SECRETS_JSON")

for config in Debug Release; do
  cat > "BuildConfiguration/$config.xcconfig" <<XCCONFIG
DEVELOPMENT_TEAM = $team
BP_ENTITLEMENTS = BookPlayer-NoCarPlay
BP_BUNDLE_IDENTIFIER = $bundle_id
BP_PROVISIONING_MAIN =
BP_PROVISIONING_WIDGET =
BP_PROVISIONING_WATCH =
BP_PROVISIONING_WATCH_WIDGETS =
BP_PROVISIONING_WIDGET_UI =
BP_PROVISIONING_SHARE_EXTENSION =
BP_SENTRY_DSN = replace.me
BP_REVENUECAT_KEY = replace.me
BP_API_SCHEME = https
BP_API_DOMAIN = replace.me
BP_API_PORT =
BP_HARDCOVER_CLIENT_ID = $hardcover
XCCONFIG
done
echo "Wrote BuildConfiguration/{Debug,Release}.xcconfig for $bundle_id"

# Run by hand with build = "diag": report the App ID's capabilities and its newest profile's
# entitlements (names only), then stop before archiving
if [ "$(jq -r '.inputs.build // empty' "$GITHUB_EVENT_PATH" 2>/dev/null)" = "diag" ]; then
  python3 - "$bundle_id" <<'PY'
import base64, os, plistlib, subprocess, sys, urllib.parse
sys.path.insert(0, os.path.join(os.environ["GITHUB_WORKSPACE"], ".github", "scripts"))
import asc
token = asc.make_token()
ident = sys.argv[1]
found = asc.call("GET", "/bundleIds?filter[identifier]=" + urllib.parse.quote(ident) + "&limit=20", token)
item = next((i for i in found.get("data", []) if i["attributes"]["identifier"] == ident), None)
if not item:
    print("App ID", ident, "not found"); sys.exit(0)
caps = asc.call("GET", "/bundleIds/{}/bundleIdCapabilities".format(item["id"]), token)
print("Capabilities on", ident + ":", sorted(c["attributes"].get("capabilityType", "?") for c in caps.get("data", [])))
profiles = asc.call("GET", "/bundleIds/{}/profiles".format(item["id"]), token).get("data", [])
profiles.sort(key=lambda p: p["attributes"].get("createdDate", ""))
if profiles:
    newest = profiles[-1]["attributes"]
    decoded = subprocess.run(["security", "cms", "-D"], input=base64.b64decode(newest["profileContent"]), capture_output=True).stdout
    print("Newest profile", newest.get("name"), "entitlements:", sorted(plistlib.loads(decoded).get("Entitlements", {}).keys()))
PY
  echo "::error::Diagnostics only (build = diag): stopping before the archive"
  exit 1
fi

# Xcode 27.1 can't sign in with the API key on GitHub's runner, so when a distribution
# certificate is available, sign and upload here, through the API instead
if [ -n "$(jq -r '.BUILD_CERTIFICATE_P12_BASE64 // empty' <<<"$SECRETS_JSON")" ]; then
  bash "$GITHUB_WORKSPACE/.github/scripts/archive-and-upload.sh" "$team" "$bundle_id"
else
  echo "::warning::No BUILD_CERTIFICATE_P12_BASE64 secret: leaving signing to Xcode"
fi
