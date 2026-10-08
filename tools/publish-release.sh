#!/bin/bash
# Attaches a notarized PasDisk build and its Sparkle appcast to an existing
# GitHub release (created by release-please). Run by .github/workflows/
# release.yml after `make app` signed PasDisk.app with the Developer ID.
#
#   tools/publish-release.sh <version> <tag>
#
# Environment: NOTARY_KEY_P8 (App Store Connect API key, .p8 contents),
# NOTARY_KEY_ID, NOTARY_ISSUER, SPARKLE_PRIVATE_KEY (EdDSA, from
# generate_keys -x), GH_TOKEN. Locally, NOTARY_PROFILE=<keychain profile>
# may replace the three NOTARY_* values.
set -euo pipefail

VERSION="${1:?version}"
TAG="${2:?tag}"
REPO="${GITHUB_REPOSITORY:-ikari-pl/PasDisk}"
OUT="build/release/$VERSION"
SPARKLE_BIN="build/sparkle/bin"

cd "$(dirname "$0")/.."
rm -rf "$OUT" && mkdir -p "$OUT"
SECRETS="$(mktemp -d)"
trap 'rm -rf "$SECRETS"' EXIT

echo "==> Notarizing PasDisk $VERSION"
ditto -c -k --keepParent PasDisk.app "$SECRETS/notarize.zip"
if [ -n "${NOTARY_KEY_P8:-}" ]; then
	printf '%s' "$NOTARY_KEY_P8" > "$SECRETS/AuthKey.p8"
	CREDS=(--key "$SECRETS/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
	CREDS=(--keychain-profile "${NOTARY_PROFILE:?NOTARY_KEY_P8 or NOTARY_PROFILE}")
fi
xcrun notarytool submit "$SECRETS/notarize.zip" "${CREDS[@]}" --wait --timeout 30m
xcrun stapler staple PasDisk.app
xcrun stapler validate PasDisk.app
spctl --assess --type execute --verbose=2 PasDisk.app

echo "==> Packaging"
ZIP="$OUT/PasDisk-$VERSION.zip"
ditto -c -k --keepParent PasDisk.app "$ZIP"

echo "==> Appcast"
KEY_ARGS=()
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
	printf '%s' "$SPARKLE_PRIVATE_KEY" > "$SECRETS/sparkle.key"
	KEY_ARGS=(--ed-key-file "$SECRETS/sparkle.key")
fi
"$SPARKLE_BIN/generate_appcast" "${KEY_ARGS[@]}" \
	--download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
	--link "https://github.com/$REPO" \
	-o "$OUT/appcast.xml" "$OUT"

echo "==> Uploading to $TAG"
gh release upload "$TAG" --repo "$REPO" --clobber "$ZIP" "$OUT/appcast.xml"
