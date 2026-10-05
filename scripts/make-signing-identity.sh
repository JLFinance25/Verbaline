#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain so locally built Verbaline keeps
# its macOS permissions across rebuilds. Optional. The certificate only signs apps on your own Mac.
#
#   scripts/make-signing-identity.sh ["Certificate Name"]
#
# Then put VERBALINE_SIGN_IDENTITY="Certificate Name" in local.env. The first build may show a keychain
# prompt for codesign; choose "Always Allow". To remove it later, delete the certificate in Keychain Access.
set -euo pipefail
NAME="${1:-Verbaline Local Signing}"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "A certificate named \"$NAME\" already exists."; exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/cfg" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" \
  -passout "pass:$PASS" -name "$NAME"
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS"
echo "Created \"$NAME\". Add this line to local.env:"
echo "VERBALINE_SIGN_IDENTITY=\"$NAME\""
