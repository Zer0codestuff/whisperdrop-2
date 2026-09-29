#!/bin/bash
# Create the stable local code-signing identity "WhisperDrop 2 Local".
# Idempotent. Safe to re-run. Does not change trust settings.
#
# KEYCHAIN
#   Keychain file to import into. When unset, import uses the default
#   keychain, which is the login keychain for a normal GUI session.
# KEYCHAIN_PASSWORD
#   Password used only to unlock KEYCHAIN before import. Leave unset when
#   the login keychain is already unlocked.
#
# Trust: security find-identity -v hides this certificate until it is
# trusted for code signing (CSSMERR_TP_NOT_TRUSTED). codesign still signs
# with it. This script does not call security add-trusted-cert, because
# that writes the user trust settings and prompts for a password.
# See signing_notes.md.

set -euo pipefail
umask 077

IDENTITY='WhisperDrop 2 Local'

identity_present() {
  local verbose all
  if [[ -n "${KEYCHAIN:-}" ]]; then
    verbose="$(security find-identity -v -p codesigning "$KEYCHAIN" || true)"
    all="$(security find-identity -p codesigning "$KEYCHAIN" || true)"
  else
    verbose="$(security find-identity -v -p codesigning || true)"
    all="$(security find-identity -p codesigning || true)"
  fi
  printf '%s\n%s\n' "$verbose" "$all" | grep -F "\"${IDENTITY}\"" >/dev/null
}

if identity_present; then
  echo "Identity already present: ${IDENTITY}"
  exit 0
fi

if [[ -n "${KEYCHAIN:-}" && ! -f "$KEYCHAIN" ]]; then
  echo "Keychain not found: ${KEYCHAIN}" >&2
  exit 1
fi

if [[ -n "${KEYCHAIN:-}" && -n "${KEYCHAIN_PASSWORD:-}" ]]; then
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${script_dir}/.signing-tmp.XXXXXX")"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cat > "$tmp/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = codesign_ext
prompt = no
[dn]
CN = WhisperDrop 2 Local
[codesign_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/openssl.cnf" \
  >/dev/null 2>&1
openssl rand -hex 24 > "$tmp/pass"

# OpenSSL 3 defaults to AES-256-CBC and PBKDF2. Older macOS security import
# rejects that PKCS#12. -legacy is 3DES for the key and RC2-40 for the cert,
# which Security.framework accepts. LibreSSL has no -legacy flag and already
# emits that older encryption. macOS 27 accepts the OpenSSL 3 default as well.
# Legacy is still what we write, so the file stays importable on older macOS.
ver="$(openssl version)"
legacy=0
case "$ver" in
  LibreSSL*) legacy=0 ;;
  OpenSSL\ 3*) legacy=1 ;;
  *) legacy=0 ;;
esac

export_p12() {
  local mode="$1"
  rm -f "$tmp/id.p12"
  if [[ "$mode" == legacy ]]; then
    openssl pkcs12 -export -legacy \
      -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -name "$IDENTITY" -out "$tmp/id.p12" -passout "file:$tmp/pass"
  else
    openssl pkcs12 -export \
      -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -name "$IDENTITY" -out "$tmp/id.p12" -passout "file:$tmp/pass"
  fi
}

import_p12() {
  local -a args
  args=(import "$tmp/id.p12" -f pkcs12 -P "$(cat "$tmp/pass")" -T /usr/bin/codesign)
  if [[ -n "${KEYCHAIN:-}" ]]; then
    args+=(-k "$KEYCHAIN")
  fi
  security "${args[@]}"
}

imported=0
if [[ "$legacy" -eq 1 ]]; then
  export_p12 legacy
  if import_p12; then
    imported=1
  else
    echo "Legacy PKCS#12 import failed. Retrying with OpenSSL 3 default encryption." >&2
    export_p12 default
    if import_p12; then
      imported=1
    fi
  fi
else
  export_p12 default
  if import_p12; then
    imported=1
  fi
fi

if [[ "$imported" -ne 1 ]]; then
  echo "Failed to import ${IDENTITY}" >&2
  exit 1
fi

if ! identity_present; then
  echo "Import reported success but ${IDENTITY} is not in the keychain." >&2
  exit 1
fi

echo "Created identity: ${IDENTITY}"
echo "OpenSSL: ${ver}"
echo "PKCS#12 encryption: $([[ "$legacy" -eq 1 ]] && echo legacy || echo default)"
