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
