#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain so locally built Verbaline keeps
# its macOS permissions across rebuilds. Optional. The certificate only signs apps on your own Mac.
#
#   scripts/make-signing-identity.sh ["Certificate Name"]
#
# It also adds VERBALINE_SIGN_IDENTITY="Certificate Name" to local.env (next to build.sh), unless local.env
# already names one. The first build may show a keychain prompt for codesign; choose "Always Allow".
# It doesn't change any trust settings. To remove it later, delete the certificate in Keychain Access.
set -euo pipefail
NAME="${1:-Verbaline Local Signing}"
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/local.env"
use_in_local_env() {
  if [[ -f "$ENV_FILE" ]] && grep -q '^VERBALINE_SIGN_IDENTITY=' "$ENV_FILE"; then
    echo "local.env already sets VERBALINE_SIGN_IDENTITY; left unchanged:"
    grep '^VERBALINE_SIGN_IDENTITY=' "$ENV_FILE"
  else
    [[ -s "$ENV_FILE" && -n "$(tail -c1 "$ENV_FILE")" ]] && echo >> "$ENV_FILE"   # no trailing newline
    echo "VERBALINE_SIGN_IDENTITY=\"$NAME\"" >> "$ENV_FILE"
    echo "Added VERBALINE_SIGN_IDENTITY=\"$NAME\" to local.env."
  fi
}
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "A certificate named \"$NAME\" already exists."
  use_in_local_env
  exit 0
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
echo "Created \"$NAME\" in your login keychain."
use_in_local_env
echo "Rebuild with ./build.sh --install; permissions will now survive rebuilds."
