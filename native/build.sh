#!/bin/bash
# Builds the AirClick desktop app from main.swift into AirClick.app.
# Prefers a stable self-signed identity (created by make-signing-cert.sh) — the
# Accessibility grant keys to the certificate and survives rebuilds. Ad-hoc
# signing pins the binary hash, so each rebuild re-breaks the grant.
set -e
cd "$(dirname "$0")"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required for the Swift compiler."
  echo "Install them with:  xcode-select --install"
  exit 1
fi
APP=AirClick.app
IDENT="AirClick Dev"
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$IDENT\""; then
  IDENT="-"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/AirClick" main.swift
cp Info.plist "$APP/Contents/Info.plist"
cp AirClick.icns "$APP/Contents/Resources/"
codesign --force --sign "$IDENT" "$APP"
echo "Built $APP (signed: $IDENT) — launch with: open $APP"