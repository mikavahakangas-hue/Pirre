#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="10.2.0"
PAYLOAD_COMMIT="6ec9f73b0aaab3c1d5452552c025741c5b0c1b53"
PAYLOAD_BASE="https://raw.githubusercontent.com/mikavahakangas-hue/Pirre/${PAYLOAD_COMMIT}/releases/v10_2_payload"
PAYLOAD_GZ_SHA256="a4683f47dfe2acd59d280fd865b5417ad51ffaff7500959330da6e0fa4f69b1e"
INSTALLER_SHA256="cf573b0166fdafcfb747862930f3875afc04424a5351f396db5eea9f82dbcc36"
TMP="$(mktemp -d /tmp/nspire-v102.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "VIRHE: $*" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || fail "curl puuttuu"
command -v base64 >/dev/null 2>&1 || fail "base64 puuttuu"
command -v gzip >/dev/null 2>&1 || fail "gzip puuttuu"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum puuttuu"

printf '\nNSPIRE V%s – ladataan lukittu asennuspaketti\n' "$VERSION"
for part in 00 01 02 03; do
  curl -fL --retry 3 --connect-timeout 15 \
    "$PAYLOAD_BASE/v102_payload_part_${part}.b64" \
    -o "$TMP/part_${part}.b64"
done
cat "$TMP"/part_*.b64 > "$TMP/payload.b64"
base64 -d "$TMP/payload.b64" > "$TMP/payload.sh.gz"
printf '%s  %s\n' "$PAYLOAD_GZ_SHA256" "$TMP/payload.sh.gz" | sha256sum -c -
gzip -dc "$TMP/payload.sh.gz" > "$TMP/nspire-v102-installer.sh"
printf '%s  %s\n' "$INSTALLER_SHA256" "$TMP/nspire-v102-installer.sh" | sha256sum -c -
chmod +x "$TMP/nspire-v102-installer.sh"
bash -n "$TMP/nspire-v102-installer.sh"

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  bash "$TMP/nspire-v102-installer.sh"
else
  command -v sudo >/dev/null 2>&1 || fail "sudo puuttuu"
  sudo bash "$TMP/nspire-v102-installer.sh"
fi
