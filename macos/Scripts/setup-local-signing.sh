#!/bin/bash
# Creates a stable LOCAL code-signing identity ("REDDY Local Signing") in its own keychain file, so every build of REDDY
# has the same signature. macOS then remembers "Always Allow" for the Keychain item that holds your IPTV login, instead of
# asking again after each rebuild. Your login keychain is not modified.
# This identity is for development on this Mac only; for distribution use a Developer ID (Scripts/sign-app.sh).
set -euo pipefail
NAME="REDDY Local Signing"
KC="$HOME/Library/Keychains/reddy-signing.keychain-db"
PW="reddy-local-signing"
if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then echo "✔ $NAME already set up"; exit 0; fi
WORK="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$PW" 2>/dev/null
[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # never auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
rm -rf "$WORK"
echo "✔ created '$NAME' in $KC"
