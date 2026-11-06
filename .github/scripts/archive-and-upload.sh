#!/bin/bash
# Archives Driftwood with manual signing and uploads it to TestFlight, without Xcode's own
# sign-in (Xcode 27.1 on GitHub's runner rejects the App Store Connect key there). Run by
# pre-build.sh when the BUILD_CERTIFICATE_P12_BASE64 secret (an Apple Distribution certificate,
# from Dev_deploy_setup's "Rotate distribution certificate") is set.
#
# Env: SECRETS_JSON, ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, team ($1), bundle ID ($2)
set -euo pipefail

team="$1"
bundle_id="$2"
scripts="$GITHUB_WORKSPACE/.github/scripts"
work="$RUNNER_TEMP/manual-signing"
mkdir -p "$work"

secret() { jq -r --arg name "$1" '.[$name] // empty' <<<"$SECRETS_JSON"; }

# 1. The distribution certificate, in a keychain of its own
keychain="$work/distribution.keychain-db"
keychain_password=$(openssl rand -hex 16)
secret BUILD_CERTIFICATE_P12_BASE64 | base64 --decode > "$work/distribution.p12"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
# The .p12 uses modern (AES / SHA-256 MAC) encryption, which macOS's importer rejects ("MAC
# verification failed"): unpack it with openssl and import the key and certificate as PEM
export P12_PASS="$(secret P12_PASSWORD)"
openssl pkcs12 -in "$work/distribution.p12" -passin env:P12_PASS -nocerts -nodes -out "$work/key.pem"
openssl pkcs12 -in "$work/distribution.p12" -passin env:P12_PASS -clcerts -nokeys -out "$work/cert.pem"
# Repack as the legacy .p12 macOS reads (3DES, SHA-1 MAC)
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout env:P12_PASS -out "$work/legacy.p12" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
       -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
       -passout env:P12_PASS -out "$work/legacy.p12"
security import "$work/legacy.p12" -k "$keychain" -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security
unset P12_PASS
rm -f "$work/key.pem" "$work/cert.pem" "$work/legacy.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
rm -f "$work/distribution.p12"

serial=$(security find-certificate -a -c "Apple Distribution" -p "$keychain" | openssl x509 -noout -serial | cut -d= -f2)
identity=$(security find-identity -v -p codesigning "$keychain" | grep "Apple Distribution" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -z "$identity" ]; then echo "::error::No Apple Distribution identity in BUILD_CERTIFICATE_P12_BASE64"; exit 1; fi
echo "Signing as: $identity"

# 2. App IDs and App Store profiles, through the API
profiles=$(python3 "$scripts/manual_signing.py" --bundle-id "$bundle_id" --certificate-serial "$serial")
profile() { jq -r --arg id "$1" '.[$id]' <<<"$profiles"; }

# The xcconfig pre-build.sh wrote, now with the profiles and the App Group-only entitlements
for config in Debug Release; do
  file="BuildConfiguration/$config.xcconfig"
  sed -i '' -E '/^BP_PROVISIONING_|^BP_ENTITLEMENTS/d' "$file"
  cat >> "$file" <<XCCONFIG
BP_ENTITLEMENTS = BookPlayer-Personal
BP_PROVISIONING_MAIN = $(profile "$bundle_id")
BP_PROVISIONING_WATCH = $(profile "$bundle_id.watchkitapp")
BP_PROVISIONING_WATCH_WIDGETS = $(profile "$bundle_id.watchkitapp.widgets")
BP_PROVISIONING_WIDGET_UI = $(profile "$bundle_id.BookPlayerWidgetUI")
BP_PROVISIONING_SHARE_EXTENSION = $(profile "$bundle_id.BookPlayerShareExtension")
XCCONFIG
done

# 3. Version and build number: 1.0, after the newest build App Store Connect has
version="1.0"
build=$(python3 "$scripts/asc.py" next-build --bundle-id "$bundle_id" --version "$version" || echo 1)
echo "Building Driftwood $version ($build)"

# 4. Archive (the project's own manual signing settings, filled in by the xcconfig)
mkdir -p build
xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Driftwood.xcarchive \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
  OTHER_CODE_SIGN_FLAGS="--keychain $keychain" \
  ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  archive > build/manual-archive.log 2>&1 || {
    grep -E ': error: ' build/manual-archive.log | sort -u | head -30 | while IFS= read -r line; do
      echo "::error::$(echo "$line" | sed -E "s#^$GITHUB_WORKSPACE/##")"
    done
    tail -60 build/manual-archive.log
    exit 1
  }
echo "Archived"

# 5. Export an .ipa signed for the App Store
cat > build/ExportOptions-manual.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>provisioningProfiles</key><dict>
    <key>$bundle_id</key><string>$(profile "$bundle_id")</string>
    <key>$bundle_id.watchkitapp</key><string>$(profile "$bundle_id.watchkitapp")</string>
    <key>$bundle_id.watchkitapp.widgets</key><string>$(profile "$bundle_id.watchkitapp.widgets")</string>
    <key>$bundle_id.BookPlayerWidgetUI</key><string>$(profile "$bundle_id.BookPlayerWidgetUI")</string>
    <key>$bundle_id.BookPlayerShareExtension</key><string>$(profile "$bundle_id.BookPlayerShareExtension")</string>
  </dict>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/Driftwood.xcarchive \
  -exportOptionsPlist build/ExportOptions-manual.plist -exportPath build/export
ipa=$(ls build/export/*.ipa | head -1)
echo "Exported $ipa"

# 6. Upload (altool finds the key in ~/.appstoreconnect/private_keys, where pre-build.sh put it)
if ! xcrun altool --upload-app --type ios --file "$ipa" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"; then
  echo "altool didn't upload it; trying Transporter"
  xcrun iTMSTransporter -m upload -assetFile "$ipa" -apiKey "$ASC_KEY_ID" -apiIssuer "$ASC_ISSUER_ID" -v informational
fi
echo "Uploaded Driftwood $version ($build) to TestFlight"
echo "### TestFlight: uploaded Driftwood $version ($build), signed through the API (pre-build.sh)" >> "$GITHUB_STEP_SUMMARY"

security delete-keychain "$keychain" || true
