#!/bin/bash
# Creates a stable self-signed "AirClick Dev" code-signing identity and signs
# AirClick.app with it. macOS records the Accessibility permission against the
# CERTIFICATE instead of the binary hash, so the grant survives every rebuild
# after one final re-toggle (script run + one toggle, and never again).
#
# Run it yourself:
#   ! bash native/make-signing-cert.sh
# (It adds one trusted certificate called "AirClick Dev" to your login
#  keychain and may ask for your password once.)
set -e
cd "$(dirname "$0")"

IDENT="AirClick Dev"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ac.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = AirClick Dev
O = AirClick
[v3]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

echo "→ generating $IDENT key + certificate…"
openssl genrsa -out "$WORK/ac.key" 2048 2>/dev/null
openssl req -new -x509 -key "$WORK/ac.key" -out "$WORK/ac.cer" -days 7300 -config "$WORK/ac.cnf"

echo "→ importing into login keychain…"
security import "$WORK/ac.cer" -k ~/Library/Keychains/login.keychain-db 2>/dev/null
security import "$WORK/ac.key" -k ~/Library/Keychains/login.keychain-db 2>/dev/null

echo "→ trusting $IDENT as a code-signing root (this is the keychain step)…"
security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db "$WORK/ac.cer"

if security find-identity -p codesigning -v | grep -q "$IDENT"; then
  codesign --force --sign "$IDENT" AirClick.app
  echo "✓ AirClick.app signed with '$IDENT'."
  echo "  Now: quit AirClick, relaunch it, toggle the Accessibility entry OFF→ON one last time."
  echo "  Every future rebuild keeps the permission — done."
else
  echo "! Identity not found after import — app stays ad-hoc signed (re-grant per rebuild)."
fi