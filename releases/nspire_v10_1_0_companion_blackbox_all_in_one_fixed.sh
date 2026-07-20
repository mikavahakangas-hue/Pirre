#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_COMMIT="c5b2cd2260ef0e74ac187a6225ec369500be0d1e"
SOURCE_URL="https://raw.githubusercontent.com/mikavahakangas-hue/Pirre/${SOURCE_COMMIT}/releases/nspire_v10_1_0_companion_blackbox_all_in_one.sh"
TMP="$(mktemp /tmp/nspire-v101-fixed.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

command -v curl >/dev/null 2>&1 || { echo "VIRHE: curl puuttuu" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "VIRHE: python3 puuttuu" >&2; exit 1; }

curl -fL --retry 3 --connect-timeout 15 "$SOURCE_URL" -o "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

replacements = [
    (
        'ROOT = Path("/opt/nspire-v101")',
        'ROOT = Path(os.environ.get("NSPIRE_V101_ROOT", "/opt/nspire-v101"))'
    ),
    (
        'python3 "$V101_STAGE/companion.py" selftest',
        'NSPIRE_V101_ROOT="$V101_STAGE" python3 "$V101_STAGE/companion.py" selftest'
    ),
    (
        '''            device["last_seen"] = int(time.time()); changed = True
            if changed: save_paired(devices)
            return True''',
        '''            now = int(time.time())
            if now - int(device.get("last_seen", 0)) >= 300:
                device["last_seen"] = now
                save_paired(devices)
            return True'''
    ),
]

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Korjauskohdetta löytyi {count} kappaletta, odotettiin yhtä: {old[:80]!r}")
    text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
PY

chmod +x "$TMP"
bash -n "$TMP"

set +e
sudo bash "$TMP"
rc=$?
set -e

exit "$rc"
