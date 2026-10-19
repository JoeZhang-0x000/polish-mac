#!/bin/bash
# One-time setup: create a self-signed code-signing certificate "Polish Local Signing"
# in your login keychain, so every build of Polish carries the same signature and
# macOS keeps the Accessibility permission across rebuilds.
#
# macOS will ask for your login password once, to mark the certificate as trusted
# for code signing. The certificate is only usable on this Mac.
#
# To remove it later: open Keychain Access, search "Polish Local Signing", delete it.
set -euo pipefail

NAME="Polish Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists and is valid; nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# /usr/bin/openssl (LibreSSL) writes a PKCS#12 file that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:polish -name "$NAME"

# -T lets codesign use the private key without a keychain prompt on every build.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P polish -T /usr/bin/codesign
echo "Marking the certificate as trusted for code signing (macOS will ask for your password)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Done. ./scripts/build_app.sh will now sign with \"$NAME\"."
  echo "Re-grant Accessibility once after the next build; after that it persists."
else
  echo "The certificate was imported but is not valid for code signing yet." >&2
  echo "Open Keychain Access, double-click \"$NAME\", and under Trust set Code Signing to Always Trust." >&2
  exit 1
fi
