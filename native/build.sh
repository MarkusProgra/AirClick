#!/bin/bash
# Builds the AirClick desktop app from main.swift into AirClick.app.
# Prefers a stable self-signed identity (created by make-signing-cert.sh) — the
# Accessibility grant keys to the certificate and survives rebuilds. Ad-hoc
# signing pins the binary hash, so each rebuild re-breaks the grant.
set -e
cd "$(dirname "$0")"
APP=AirClick.app
IDENT="AirClick Dev"
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$IDENT\""; then
  IDENT="-"
fi
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/AirClick" main.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$IDENT" "$APP"
echo "Built $APP (signed: $IDENT) — launch with: open $APP"