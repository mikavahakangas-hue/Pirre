#!/usr/bin/env bash
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$PKG/VERSION")"
[[ "$VERSION" == "4.38.0" ]] || { echo "VIRHE: väärä Pirre OTA -versio" >&2; exit 1; }
cd "$PKG"
sha256sum -c --quiet SHA256SUMS
TMP="$(mktemp -d -t pirre-v438-wrapper-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cat "$PKG"/payload.b64.part* | base64 -d > "$TMP/nspire_ui_v4_38_0_ota_delta.tar.gz"
echo '1dd815afff8c00ac4f68ae65a14050ea0ac1cd8e11bfe3a042e352175bd4c030  '"$TMP/nspire_ui_v4_38_0_ota_delta.tar.gz" | sha256sum -c --quiet
tar -xzf "$TMP/nspire_ui_v4_38_0_ota_delta.tar.gz" -C "$TMP"
INNER="$TMP/nspire_ui_v4_38_0_ota_delta"
[[ -f "$INNER/install.sh" && -f "$INNER/SHA256SUMS" ]] || { echo 'VIRHE: sisäinen OTA-paketti on virheellinen' >&2; exit 1; }
chmod +x "$INNER/install.sh" "$INNER/apply_patch.py" "$INNER/nspire-healthcheck"
exec bash "$INNER/install.sh"
