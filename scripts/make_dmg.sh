#!/bin/bash
# Build a universal Polish.app and package it as dist/Polish-<version>.dmg
# (drag-to-Applications layout). VERSION defaults to 0.0.1.
set -euo pipefail
cd "$(dirname "$0")/.."

export VERSION="${VERSION:-0.0.1}"
./scripts/build_app.sh --universal

DMG="dist/Polish-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R build/Polish.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "Polish $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
