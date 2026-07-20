#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="9.8.0"
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
INSTALL_ROOT="/opt/nspire-v98"
STATE_ROOT="/var/lib/nspire-v98"
BACKUP_ROOT="/var/backups/nspire-v98"
CONFIG_FILE="/etc/nspire-v98/config.json"
SERVICE_LIST="$STATE_ROOT/services.txt"
LOG_TAG="nspire-v98-installer"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; }
die(){ printf '\nVIRHE: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Aja asennus sudo-komennolla: sudo bash $SELF"

export DEBIAN_FRONTEND=noninteractive
umask 022

log "NSPIRE V${VERSION} – ALL IN ONE"
log "Esitarkistus"

bash -n "$SELF" || die "Asennustiedoston Bash-syntaksi ei kelpaa"
command -v python3 >/dev/null 2>&1 || die "python3 puuttuu"
command -v systemctl >/dev/null 2>&1 || die "systemd puuttuu"
command -v tar >/dev/null 2>&1 || die "tar puuttuu"

FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
[[ "${FREE_KB:-0}" -ge 150000 ]] || die "Vapaata levytilaa tarvitaan vähintään 150 Mt"

mkdir -p "$INSTALL_ROOT" "$STATE_ROOT" "$BACKUP_ROOT" "$(dirname "$CONFIG_FILE")"

# -----------------------------------------------------------------------------
# Löydä nykyinen käyttöliittymä ja sen palvelut
# -----------------------------------------------------------------------------

mapfile -t SERVICES < <(
  systemctl list-unit-files --type=service --no-legend 2>/dev/null |
  awk '{print $1}' |
  grep -E '^(nspire|fb1-desktop|kiosk).*\.service$' |
  grep -Ev '(watchdog|backup|v98|restore)' || true
)

if systemctl cat nspire-v4.service >/dev/null 2>&1; then
  SERVICES=(nspire-v4.service "${SERVICES[@]}")
fi

printf '%s\n' "${SERVICES[@]}" | awk 'NF&&!seen[$0]++' > "$SERVICE_LIST"

INDEX=""
CANDIDATES=(
  /var/www/html/index.html
  /opt/nspire-v4/index.html
  /opt/nspire/index.html
  /home/mavks/nspire/index.html
)

while IFS= read -r service; do
  [[ -n "$service" ]] || continue
  workdir="$(systemctl show "$service" -p WorkingDirectory --value 2>/dev/null || true)"
  [[ -n "$workdir" && "$workdir" != / ]] && CANDIDATES+=("$workdir/index.html")
done < "$SERVICE_LIST"

for candidate in "${CANDIDATES[@]}"; do
  if [[ -f "$candidate" ]] && grep -Eqi 'nspire|app-grid|settings-shell' "$candidate"; then
    INDEX="$candidate"
    break
  fi
done

if [[ -z "$INDEX" ]]; then
  INDEX="$(find /var/www /opt /home/mavks -maxdepth 6 -type f -name index.html 2>/dev/null |
    while read -r file; do grep -Eqi 'nspire|app-grid|settings-shell' "$file" && { echo "$file"; break; }; done)"
fi

[[ -n "$INDEX" && -f "$INDEX" ]] || die "NSPIRE-käyttöliittymän index.html-tiedostoa ei löytynyt"
WEB_ROOT="$(dirname "$INDEX")"
ASSET_ROOT="$WEB_ROOT/nspire98"
mkdir -p "$ASSET_ROOT"

printf '%s\n' "$INDEX" > "$STATE_ROOT/index-path.txt"
printf '%s\n' "$WEB_ROOT" > "$STATE_ROOT/web-root.txt"

log "Käyttöliittymä: $INDEX"
log "Palvelut: $(tr '\n' ' ' < "$SERVICE_LIST")"

# -----------------------------------------------------------------------------
# Varmuuskopio ennen yhtäkään muutosta
# -----------------------------------------------------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/pre-v98-$STAMP"
mkdir -p "$BACKUP/files"
cp -a "$INDEX" "$BACKUP/files/index.html"
[[ -d "$ASSET_ROOT" ]] && cp -a "$ASSET_ROOT" "$BACKUP/files/nspire98.old" || true
cp -a "$CONFIG_FILE" "$BACKUP/files/config.json" 2>/dev/null || true
cp -a "$SERVICE_LIST" "$BACKUP/files/services.txt"
printf '%s\n' "$INDEX" > "$BACKUP/index-path.txt"
printf '%s\n' "$BACKUP" > "$STATE_ROOT/last-backup.txt"

while IFS= read -r service; do
  [[ -n "$service" ]] || continue
  systemctl cat "$service" > "$BACKUP/files/${service}.unit" 2>/dev/null || true
done < "$SERVICE_LIST"

log "Varmuuskopio: $BACKUP"

# -----------------------------------------------------------------------------
# Oletusasetukset. BME680 pidetään aina käytössä.
# -----------------------------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
cat > "$CONFIG_FILE" <<'JSON'
{
  "version": "9.8.0",
  "auto_power": true,
  "manual_profile": "auto",
  "bme_always_on": true,
  "screensaver": {
    "enabled": true,
    "delay_seconds": 120,
    "dim_seconds_before": 15,
    "profile": "sofa2"
  },
  "profiles": {
    "performance": {"governor":"performance","brightness":100,"metric_seconds":4,"animations":true,"wifi":true,"vnc":true},
    "maintenance": {"governor":"ondemand","brightness":65,"metric_seconds":7,"animations":false,"wifi":true,"vnc":true},
    "saver": {"governor":"powersave","brightness":25,"metric_seconds":12,"animations":false,"wifi":true,"vnc":false}
  }
}
JSON
fi
chmod 644 "$CONFIG_FILE"

# -----------------------------------------------------------------------------
# Paikallinen hallinta-, diagnostiikka-, palautus- ja vakauspalvelu
# -----------------------------------------------------------------------------

cat > "$INSTALL_ROOT/nspire98.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
from collections import deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

VERSION = "9.8.0"
INSTALL = Path("/opt/nspire-v98")
STATE = Path("/var/lib/nspire-v98")
BACKUPS = Path("/var/backups/nspire-v98")
CONFIG = Path("/etc/nspire-v98/config.json")
SERVICES = STATE / "services.txt"
EVENTS = STATE / "events.jsonl"
WATCHDOG = STATE / "watchdog.json"
STABILITY = STATE / "stability.csv"
PORT = 8770

STATE.mkdir(parents=True, exist_ok=True)
BACKUPS.mkdir(parents=True, exist_ok=True)


def run(cmd: list[str], timeout: int = 20) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, check=False)


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def atomic_json(path: Path, data: Any) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def event(kind: str, message: str, **extra: Any) -> None:
    row = {"time": int(time.time()), "kind": kind, "message": message, **extra}
    with EVENTS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    try:
        lines = EVENTS.read_text(encoding="utf-8").splitlines()
        if len(lines) > 500:
            EVENTS.write_text("\n".join(lines[-400:]) + "\n", encoding="utf-8")
    except Exception:
        pass


def services() -> list[str]:
    try:
        return list(dict.fromkeys(x.strip() for x in SERVICES.read_text().splitlines() if x.strip()))
    except Exception:
        return []


def service_active(name: str) -> bool:
    return run(["systemctl", "is-active", "--quiet", name], 5).returncode == 0


def cpu_sample(delay: float = 0.18) -> float:
    def snap() -> tuple[int, int]:
        parts = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
        vals = [int(x) for x in parts]
        idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
        return sum(vals), idle
    a_total, a_idle = snap(); time.sleep(delay); b_total, b_idle = snap()
    total = max(1, b_total - a_total); idle = max(0, b_idle - a_idle)
    return round(100.0 * (total - idle) / total, 1)


def temperature() -> float | None:
    try:
        return round(int(Path("/sys/class/thermal/thermal_zone0/temp").read_text()) / 1000, 1)
    except Exception:
        return None


def memory() -> dict[str, float]:
    info: dict[str, int] = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        info[key] = int(value.strip().split()[0])
    total = info.get("MemTotal", 1); available = info.get("MemAvailable", 0)
    swap_total = info.get("SwapTotal", 0); swap_free = info.get("SwapFree", 0)
    return {
        "ram_percent": round(100 * (total - available) / total, 1),
        "ram_mb": round((total - available) / 1024, 1),
        "swap_percent": round(100 * (swap_total - swap_free) / swap_total, 1) if swap_total else 0.0,
    }


def battery() -> dict[str, Any]:
    result: dict[str, Any] = {"percent": None, "charging": None, "status": "unknown"}
    for base in Path("/sys/class/power_supply").glob("*") if Path("/sys/class/power_supply").exists() else []:
        try:
            status = (base / "status").read_text().strip().lower() if (base / "status").exists() else ""
            capacity = int((base / "capacity").read_text()) if (base / "capacity").exists() else None
            if capacity is not None or status:
                result["percent"] = capacity
                result["status"] = status or "unknown"
                result["charging"] = status in {"charging", "full", "not charging"}
                return result
        except Exception:
            pass
    return result


def brightness_paths() -> list[tuple[Path, Path]]:
    out = []
    for base in Path("/sys/class/backlight").glob("*") if Path("/sys/class/backlight").exists() else []:
        if (base / "brightness").exists() and (base / "max_brightness").exists():
            out.append((base / "brightness", base / "max_brightness"))
    return out


def set_brightness(percent: int) -> bool:
    percent = max(1, min(100, int(percent))); changed = False
    for current, maximum in brightness_paths():
        try:
            max_value = int(maximum.read_text()); current.write_text(str(max(1, round(max_value * percent / 100))))
            changed = True
        except Exception:
            pass
    return changed


def get_brightness() -> int | None:
    for current, maximum in brightness_paths():
        try:
            return round(100 * int(current.read_text()) / max(1, int(maximum.read_text())))
        except Exception:
            pass
    return None


def profile_name() -> str:
    return read_json(STATE / "active-profile.json", {}).get("profile", "unknown")


def apply_profile(name: str) -> dict[str, Any]:
    config = read_json(CONFIG, {})
    profiles = config.get("profiles", {})
    if name == "auto":
        b = battery(); name = "performance" if b.get("charging") is not False else "maintenance"
    profile = profiles.get(name)
    if not isinstance(profile, dict):
        raise ValueError("Tuntematon profiili")
    governor = str(profile.get("governor", "ondemand"))
    for path in Path("/sys/devices/system/cpu").glob("cpu*/cpufreq/scaling_governor"):
        try: path.write_text(governor)
        except Exception: pass
    set_brightness(int(profile.get("brightness", 60)))
    atomic_json(STATE / "active-profile.json", {"profile": name, "time": int(time.time())})
    event("power", f"Virtaprofiili {name}")
    return {"profile": name, "settings": profile}


def top_processes() -> list[dict[str, Any]]:
    result = run(["ps", "-eo", "pid,comm,%cpu,%mem,nice", "--sort=-%cpu"], 5)
    rows = []
    for line in result.stdout.splitlines()[1:8]:
        parts = line.split(None, 4)
        if len(parts) == 5:
            rows.append({"pid": int(parts[0]), "name": parts[1], "cpu": float(parts[2]),
                         "memory": float(parts[3]), "nice": int(parts[4])})
    return rows


def recent_events() -> list[dict[str, Any]]:
    try:
        lines = deque(EVENTS.read_text(encoding="utf-8").splitlines(), maxlen=40)
        return [json.loads(x) for x in lines if x.strip()]
    except Exception:
        return []


def status() -> dict[str, Any]:
    mem = memory(); b = battery(); w = read_json(WATCHDOG, {})
    return {
        "version": VERSION, "time": int(time.time()), "cpu_percent": cpu_sample(),
        "temperature_c": temperature(), **mem, "battery": b, "brightness": get_brightness(),
        "profile": profile_name(), "services": [{"name": x, "active": service_active(x)} for x in services()],
        "watchdog": w, "events": recent_events(), "top_processes": top_processes(),
        "config": read_json(CONFIG, {}),
    }


def restart_ui() -> list[str]:
    restarted = []
    ordered = sorted(services(), key=lambda x: ("kiosk" in x or "desktop" in x or "ui.service" in x, x))
    for name in ordered:
        if run(["systemctl", "restart", name], 35).returncode == 0:
            restarted.append(name)
        time.sleep(1)
    event("maintenance", "Käyttöliittymä käynnistettiin turvallisesti uudelleen", services=restarted)
    return restarted


def make_backup(label: str = "manual") -> str:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output = BACKUPS / f"{label}-{stamp}.tar.gz"
    candidates = [Path("/etc/nspire-v98"), STATE, Path("/var/www/html/nspire98"), Path("/opt/nspire-v98")]
    index_path = STATE / "index-path.txt"
    if index_path.exists():
        try: candidates.append(Path(index_path.read_text().strip()))
        except Exception: pass
    with tarfile.open(output, "w:gz") as tar:
        for path in candidates:
            if path.exists(): tar.add(path, arcname=str(path).lstrip("/"), recursive=True)
    files = sorted(BACKUPS.glob("*.tar.gz"), key=lambda p: p.stat().st_mtime, reverse=True)
    for old in files[12:]:
        try: old.unlink()
        except Exception: pass
    event("backup", "Varmuuskopio luotu", path=str(output))
    return str(output)


def diagnostics() -> str:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out = Path("/home/mavks") / f"nspire-v98-diagnostics-{stamp}.txt"
    sections = [
        ("STATUS", json.dumps(status(), ensure_ascii=False, indent=2)),
        ("UPTIME", run(["uptime"], 5).stdout),
        ("MEMORY", run(["free", "-h"], 5).stdout),
        ("DISK", run(["df", "-h", "/"], 5).stdout),
        ("TIMERS", run(["systemctl", "list-timers", "--no-pager"], 10).stdout),
        ("NSPIRE JOURNAL", run(["journalctl", "--no-pager", "-n", "350", "-u", "nspire-v98-api.service",
                                 "-u", "nspire-v98-watchdog.service", "-u", "nspire-v98-power.service"], 20).stdout),
    ]
    out.write_text("\n\n".join(f"===== {title} =====\n{text}" for title, text in sections), encoding="utf-8")
    try: shutil.chown(out, user="mavks", group="mavks")
    except Exception: pass
    event("diagnostics", "Diagnostiikkaraportti luotu", path=str(out))
    return str(out)


def stability_sample() -> None:
    s = status(); new = not STABILITY.exists()
    with STABILITY.open("a", encoding="utf-8") as f:
        if new: f.write("time,cpu,temp,ram,swap,profile,restarts\n")
        f.write(f"{s['time']},{s['cpu_percent']},{s['temperature_c']},{s['ram_percent']},"
                f"{s['swap_percent']},{s['profile']},{s['watchdog'].get('restart_count',0)}\n")
    lines = STABILITY.read_text().splitlines()
    if len(lines) > 600: STABILITY.write_text("\n".join([lines[0]] + lines[-500:]) + "\n")


def watchdog_check() -> None:
    state = read_json(WATCHDOG, {"failures": 0, "last_restart": 0, "restart_count": 0})
    active = [x for x in services() if service_active(x)]
    healthy = bool(active) and len(active) >= max(1, len(services()) // 2)
    now = int(time.time())
    if healthy:
        state["failures"] = 0; state["last_success"] = now; state["action"] = "healthy"
    else:
        state["failures"] = int(state.get("failures", 0)) + 1; state["last_failure"] = now
        state["action"] = "failure-recorded"
        if state["failures"] >= 3 and now - int(state.get("last_restart", 0)) >= 300:
            restarted = restart_ui(); state["failures"] = 0; state["last_restart"] = now
            state["restart_count"] = int(state.get("restart_count", 0)) + 1
            state["action"] = "restarted"; state["restarted"] = restarted
            event("watchdog", "Watchdog käynnisti palvelut uudelleen", services=restarted)
        elif state["failures"] >= 3:
            state["action"] = "cooldown"
    state["last_check"] = now; state["active_services"] = active
    atomic_json(WATCHDOG, state)


def auto_power() -> None:
    config = read_json(CONFIG, {})
    manual = config.get("manual_profile", "auto")
    if manual in {"performance", "maintenance", "saver"}: apply_profile(manual)
    else: apply_profile("auto")


class Handler(BaseHTTPRequestHandler):
    server_version = "NSPIRE98/1"
    def _headers(self, status_code: int = 200) -> None:
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
    def _json(self, payload: Any, status_code: int = 200) -> None:
        self._headers(status_code); self.wfile.write(json.dumps(payload, ensure_ascii=False).encode())
    def do_OPTIONS(self) -> None: self._headers(204)
    def do_GET(self) -> None:
        if self.path == "/api/status":
            try: self._json(status())
            except Exception as exc: self._json({"ok": False, "error": str(exc)}, 500)
        elif self.path == "/api/stability":
            try: self._json({"ok": True, "csv": STABILITY.read_text()[-30000:] if STABILITY.exists() else ""})
            except Exception as exc: self._json({"ok": False, "error": str(exc)}, 500)
        else: self._json({"ok": True, "version": VERSION})
    def do_POST(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0")); body = self.rfile.read(length) if length else b"{}"
            data = json.loads(body.decode() or "{}"); action = data.get("action")
            if action == "restart": result = restart_ui()
            elif action == "backup": result = make_backup()
            elif action == "diagnostics": result = diagnostics()
            elif action == "profile": result = apply_profile(str(data.get("profile", "auto")))
            elif action == "brightness": result = set_brightness(int(data.get("value", 60)))
            elif action == "screen_off": result = set_brightness(1)
            elif action == "wifi":
                enabled = bool(data.get("enabled", True)); cmd = ["nmcli", "radio", "wifi", "on" if enabled else "off"]
                result = run(cmd, 15).returncode == 0
            elif action == "vnc":
                enabled = bool(data.get("enabled", True)); result = []
                for name in ["vncserver-x11-serviced.service", "x11vnc.service", "wayvnc.service"]:
                    if run(["systemctl", "cat", name], 5).returncode == 0:
                        run(["systemctl", "enable" if enabled else "disable", "--now", name], 20); result.append(name)
            elif action == "event":
                event(str(data.get("kind", "ui")), str(data.get("message", ""))); result = True
            else: raise ValueError("Tuntematon toiminto")
            self._json({"ok": True, "result": result})
        except Exception as exc: self._json({"ok": False, "error": str(exc)}, 400)
    def log_message(self, fmt: str, *args: Any) -> None: pass


def daemon() -> None:
    event("boot", "NSPIRE V9.8 hallintapalvelu käynnistyi")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser(); parser.add_argument("command", nargs="?", default="daemon")
    args = parser.parse_args()
    if args.command == "daemon": daemon()
    elif args.command == "watchdog": watchdog_check()
    elif args.command == "backup": print(make_backup("automatic"))
    elif args.command == "sample": stability_sample()
    elif args.command == "power": auto_power()
    elif args.command == "diagnostics": print(diagnostics())
    elif args.command == "status": print(json.dumps(status(), ensure_ascii=False, indent=2))
    elif args.command == "restart": print(restart_ui())
    else: raise SystemExit("Tuntematon komento")

if __name__ == "__main__": main()
PY
chmod 755 "$INSTALL_ROOT/nspire98.py"
python3 -m py_compile "$INSTALL_ROOT/nspire98.py" || die "Hallintapalvelun Python-tarkistus epäonnistui"

# -----------------------------------------------------------------------------
# Kevyt, yleiskäyttöinen käyttöliittymäkerros
# -----------------------------------------------------------------------------

cat > "$ASSET_ROOT/nspire98.css" <<'CSS'
:root{--n98-bg:#0b1119;--n98-card:#15202d;--n98-line:#31445b;--n98-text:#f3f7fb;--n98-muted:#aebdca;--n98-accent:#65bfff;--n98-good:#78d99a;--n98-warn:#ffd166;--n98-bad:#ff7878}
#n98-pill{position:fixed;z-index:2147483000;right:8px;top:5px;height:31px;padding:0 11px;border:1px solid var(--n98-line);border-radius:16px;background:rgba(11,17,25,.94);color:var(--n98-text);font:600 13px/29px system-ui;box-shadow:0 3px 12px #0008;cursor:pointer;user-select:none}
#n98-pill.warn{color:var(--n98-warn)}#n98-pill.bad{color:var(--n98-bad)}
#n98-panel,#n98-settings,#n98-safe{position:fixed;z-index:2147483200;inset:42px 7px 7px;background:rgba(8,13,20,.985);color:var(--n98-text);border:1px solid var(--n98-line);border-radius:14px;box-shadow:0 8px 30px #000c;overflow:auto;padding:12px;font-family:system-ui}
.n98-hidden{display:none!important}.n98-head{display:flex;align-items:center;justify-content:space-between;gap:8px;position:sticky;top:-12px;background:#080d14;padding:8px 0;z-index:2}.n98-head h2{font-size:18px;margin:0}.n98-close{min-width:42px;min-height:35px;border-radius:9px;border:1px solid var(--n98-line);background:var(--n98-card);color:var(--n98-text);font-size:18px}
.n98-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}.n98-card{background:var(--n98-card);border:1px solid var(--n98-line);border-radius:11px;padding:9px;min-width:0}.n98-card b{display:block;font-size:18px;margin-top:3px}.n98-card small{color:var(--n98-muted)}
.n98-actions{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:7px;margin:10px 0}.n98-actions button,.n98-profile,.n98-jump{min-height:45px;border:1px solid var(--n98-line);border-radius:10px;background:var(--n98-card);color:var(--n98-text);font:600 13px system-ui;padding:6px}.n98-actions button:active,.n98-profile:active{transform:scale(.98)}
.n98-section{margin:12px 0 6px;color:var(--n98-accent);font-weight:700}.n98-range{width:100%}.n98-log{font:12px/1.35 ui-monospace,monospace;white-space:pre-wrap;background:#060a10;border-radius:9px;padding:8px;max-height:150px;overflow:auto;color:#cbd8e3}
#n98-scroll{position:fixed;z-index:2147483050;right:7px;top:50%;transform:translateY(-50%);display:grid;gap:8px}#n98-scroll button{width:43px;height:43px;border-radius:50%;border:1px solid var(--n98-line);background:rgba(11,17,25,.9);color:#fff;font-size:23px;box-shadow:0 2px 9px #0009}#n98-scroll button:disabled{opacity:.28}
#n98-home{position:fixed;z-index:2147483040;left:7px;top:6px;width:38px;height:31px;border-radius:9px;border:1px solid var(--n98-line);background:rgba(11,17,25,.92);color:#fff;font-size:19px}
#n98-saver{position:fixed;z-index:2147483500;inset:0;background:#020407;color:#eef7ff;display:flex;align-items:center;justify-content:center;font-family:system-ui;font-weight:400}#n98-saver .clock{font-size:min(24vw,126px);font-weight:300;letter-spacing:-5px}#n98-saver .sub{font-size:18px;text-align:center;color:#aab9c7;font-weight:400}
.saver-sofa,.saver-sofa *,.saver-sofa2,.saver-sofa2 *,[data-saver-profile="sofa2"],[data-saver-profile="sofa2"] *{font-weight:400!important}
.app-grid,.home-grid{grid-template-columns:repeat(6,minmax(0,1fr))!important;grid-auto-rows:minmax(65px,1fr)!important;gap:6px!important}.app-grid>.app-tile,.home-grid>.app-tile{min-width:0!important}
body.n98-lite *,body.n98-lite *::before,body.n98-lite *::after{animation-duration:0s!important;transition-duration:0s!important;scroll-behavior:auto!important}
@media(max-width:700px){.n98-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.n98-actions{grid-template-columns:repeat(2,minmax(0,1fr))}}
CSS

cat > "$ASSET_ROOT/nspire98.js" <<'JS'
(()=>{'use strict';
const API='http://127.0.0.1:8770/api';
const state={status:null,timer:null,idle:null,dim:null,saver:false,lastRepair:0,lastFolder:null};
const $=(s,r=document)=>r.querySelector(s), $$=(s,r=document)=>[...r.querySelectorAll(s)];
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function api(path='/status',body){const opt=body?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}:{};const r=await fetch(API+path,opt);if(!r.ok)throw Error('HTTP '+r.status);return r.json()}
function add(id,tag='div',parent=document.body){let e=document.getElementById(id);if(!e){e=document.createElement(tag);e.id=id;parent.appendChild(e)}return e}
function notify(message,kind='ui'){api('/action',{action:'event',kind,message}).catch(()=>{})}
function shell(){
 const home=add('n98-home','button');home.textContent='⌂';home.title='Etusivu – pitkä painallus palauttaa ruudukon';
 let hold;home.onpointerdown=()=>hold=setTimeout(()=>{repairHome(true);goHome()},650);home.onpointerup=()=>{clearTimeout(hold);goBack()};home.onpointercancel=()=>clearTimeout(hold);
 const pill=add('n98-pill','button');pill.textContent='Kuorma --%';pill.onclick=()=>openPanel();
 const scroll=add('n98-scroll');scroll.innerHTML='<button id="n98-up">▲</button><button id="n98-down">▼</button>';$('#n98-up').onclick=()=>scrollTarget(-.78);$('#n98-down').onclick=()=>scrollTarget(.78);
 const panel=add('n98-panel');panel.className='n98-hidden';
 const saver=add('n98-saver');saver.className='n98-hidden';saver.innerHTML='<div><div class="clock" id="n98-clock">--:--</div><div class="sub" id="n98-saver-sub">Kosketa tai paina näppäintä</div></div>';
 panel.addEventListener('click',panelClick);panel.addEventListener('input',panelInput);
}
function target(){const candidates=$$('main,.view.active,.screen.active,.settings-panel,.content,[data-view].active').filter(e=>e.scrollHeight>e.clientHeight+5);return candidates.sort((a,b)=>b.clientHeight-a.clientHeight)[0]||document.scrollingElement}
function scrollTarget(part){const t=target();t.scrollBy({top:Math.max(150,t.clientHeight)*part,behavior:document.body.classList.contains('n98-lite')?'auto':'smooth'})}
function updateScroll(){const t=target(),max=Math.max(0,t.scrollHeight-t.clientHeight);$('#n98-up').disabled=t.scrollTop<3;$('#n98-down').disabled=t.scrollTop>max-3;$('#n98-scroll').style.display=max>5?'grid':'none'}
function tileName(el){return (el.dataset.title||el.dataset.name||$('.app-name,.tile-title,.label',el)?.textContent||el.textContent||'').trim().replace(/\s+/g,' ')}
function isFolder(el){return el.matches('[data-folder],.folder-tile,.app-folder,[data-type="folder"]')||/kansio/i.test(el.className)}
function repairHome(force=false){const now=Date.now();if(!force&&now-state.lastRepair<900)return;state.lastRepair=now;
 const grid=$('.app-grid,.home-grid');if(!grid)return;const tiles=$$('.app-tile,.tile,[data-app]',grid).filter(x=>x.parentElement===grid);if(!tiles.length)return;
 const inFolders=new Set();$$('[data-folder],.folder-tile,.app-folder',grid).forEach(folder=>{$$('.app-tile,.tile,[data-app]',folder).forEach(x=>inFolders.add(tileName(x).toLocaleLowerCase('fi')));const raw=folder.dataset.apps;if(raw){try{JSON.parse(raw).forEach(x=>inFolders.add(String(x).toLocaleLowerCase('fi')))}catch{raw.split(',').forEach(x=>inFolders.add(x.trim().toLocaleLowerCase('fi')))}}});
 const seen=new Set();tiles.forEach(t=>{const n=tileName(t).toLocaleLowerCase('fi');const duplicate=seen.has(n)||(!isFolder(t)&&inFolders.has(n));t.hidden=duplicate;if(!duplicate)seen.add(n)});
 const visible=tiles.filter(t=>!t.hidden);visible.sort((a,b)=>{const fa=isFolder(a)?0:1,fb=isFolder(b)?0:1;return fa-fb||tileName(a).localeCompare(tileName(b),'fi')});visible.forEach(t=>grid.appendChild(t));
 ensureSettingsTile(grid);localStorage.setItem('n98-home-ok',String(Date.now()));
}
function ensureSettingsTile(grid){if($('#n98-settings-tile',grid))return;const proto=$('.app-tile,.tile',grid),t=proto?proto.cloneNode(false):document.createElement('button');t.id='n98-settings-tile';t.classList.add('app-tile');t.dataset.folder='settings';t.innerHTML='<span style="font-size:25px">⚙</span><span class="app-name">Asetukset</span>';t.onclick=e=>{e.preventDefault();openSettings()};grid.insertBefore(t,grid.firstChild)}
function goHome(){const home=$('[data-view="home"],.view-home,#home,.home-view');if(home){$$('.view.active,.screen.active,[data-view].active').forEach(x=>x.classList.remove('active'));home.classList.add('active')}else{location.hash='home'}setTimeout(()=>repairHome(true),50)}
function goBack(){const panel=$('#n98-panel');if(panel&&!panel.classList.contains('n98-hidden')){panel.classList.add('n98-hidden');return}history.length>1?history.back():goHome();setTimeout(()=>repairHome(true),80)}
function openSettings(){openPanel('settings')}
function openPanel(section='main'){const p=$('#n98-panel');p.classList.remove('n98-hidden');renderPanel(section)}
function metric(label,value,sub=''){return `<div class="n98-card"><small>${esc(label)}</small><b>${esc(value)}</b><small>${esc(sub)}</small></div>`}
function renderPanel(section='main'){const s=state.status||{},b=s.battery||{},w=s.watchdog||{},events=(s.events||[]).slice(-12).reverse();const serviceBad=(s.services||[]).filter(x=>!x.active).length;
 $('#n98-panel').innerHTML=`<div class="n98-head"><h2>NSPIRE V9.8 – ${section==='settings'?'Asetukset':'Pika-asetukset'}</h2><button class="n98-close" data-act="close">×</button></div>
 <div class="n98-grid">${metric('Kuorma',(s.cpu_percent??'--')+' %')}${metric('Lämpö',(s.temperature_c??'--')+' °C')}${metric('RAM',(s.ram_percent??'--')+' %')}${metric('Akku',b.percent==null?'-- %':b.percent+' %',b.status||'')}${metric('Profiili',s.profile||'--')}${metric('Palvelut',serviceBad?serviceBad+' vialla':'Kunnossa')}</div>
 <div class="n98-section">Virtaprofiili</div><div class="n98-actions"><button data-profile="auto">Automaattinen</button><button data-profile="performance">Teho</button><button data-profile="maintenance">Ylläpito</button><button data-profile="saver">Säästö</button><button data-act="saver">Näytönsäästäjä</button><button data-act="screenoff">Näyttö pois</button></div>
 <div class="n98-section">Kirkkaus</div><input class="n98-range" id="n98-bright" type="range" min="5" max="100" value="${s.brightness??60}">
 <div class="n98-section">Yhteydet ja huolto</div><div class="n98-actions"><button data-act="wifi-on">Wi-Fi päälle</button><button data-act="wifi-off">Wi-Fi pois</button><button data-act="vnc-on">VNC päälle</button><button data-act="vnc-off">VNC pois</button><button data-act="backup">Varmuuskopio</button><button data-act="diagnostics">Diagnostiikka</button><button data-act="restart">UI uudelleen</button><button data-act="repair">Korjaa etusivu</button><button data-act="stability">Vakaustesti</button></div>
 <div class="n98-section">Näytönsäästäjä</div><div class="n98-card">Yksi tapahtumapohjainen ajastin. Seuraava käynnistys: <b id="n98-next">--</b><small id="n98-saver-reason">Odottaa käyttäjän toimettomuutta</small></div>
 <div class="n98-section">Watchdog</div><div class="n98-card"><small>Toiminto</small><b>${esc(w.action||'odottaa')}</b><small>Restartit: ${esc(w.restart_count||0)} · Virheet: ${esc(w.failures||0)}</small></div>
 <div class="n98-section">Tapahtumat</div><div class="n98-log">${events.map(e=>new Date(e.time*1000).toLocaleTimeString('fi-FI')+' '+e.kind+': '+e.message).join('\n')||'Ei tapahtumia'}</div>`}
function panelClick(e){const b=e.target.closest('button');if(!b)return;if(b.dataset.profile)act('profile',{profile:b.dataset.profile});const a=b.dataset.act;if(a==='close')$('#n98-panel').classList.add('n98-hidden');if(a==='saver')showSaver('Käsin käynnistetty');if(a==='screenoff')act('screen_off');if(a==='wifi-on')act('wifi',{enabled:true});if(a==='wifi-off')act('wifi',{enabled:false});if(a==='vnc-on')act('vnc',{enabled:true});if(a==='vnc-off')act('vnc',{enabled:false});if(a==='backup')act('backup');if(a==='diagnostics')act('diagnostics');if(a==='restart')act('restart');if(a==='repair'){repairHome(true);goHome()}if(a==='stability')api('/stability').then(x=>alert(x.csv||'Ei vielä mittauksia')).catch(err=>alert(err.message))}
let brightDelay;function panelInput(e){if(e.target.id==='n98-bright'){clearTimeout(brightDelay);brightDelay=setTimeout(()=>act('brightness',{value:+e.target.value}),180)}}
async function act(action,extra={}){try{const x=await api('/action',{action,...extra});if(!x.ok)throw Error(x.error||'Toiminto epäonnistui');notify('Toiminto: '+action);setTimeout(refresh,500)}catch(err){alert('Virhe: '+err.message)}}
function findSaver(){for(const name of ['screensaverNow','showScreensaver','activateScreensaver','startScreensaver'])if(typeof window[name]==='function')return window[name];return null}
function showSaver(reason='Ajastin'){state.saver=true;const fn=findSaver();if(fn){try{fn();notify('Näytönsäästäjä käynnistyi: '+reason,'screensaver');return}catch(err){notify('Oma säästäjä epäonnistui: '+err.message,'error')}}const s=$('#n98-saver');s.classList.remove('n98-hidden');$('#n98-saver-sub').textContent=reason+' · kosketa tai paina näppäintä';tickClock();notify('V9.8-varanäytönsäästäjä käynnistyi: '+reason,'screensaver')}
function hideSaver(){if(!state.saver)return;state.saver=false;$('#n98-saver').classList.add('n98-hidden');resetIdle()}
function tickClock(){if(!state.saver)return;$('#n98-clock').textContent=new Date().toLocaleTimeString('fi-FI',{hour:'2-digit',minute:'2-digit'});setTimeout(tickClock,1000)}
function resetIdle(){clearTimeout(state.idle);clearTimeout(state.dim);const cfg=state.status?.config?.screensaver||{},delay=Math.max(20,+cfg.delay_seconds||120),dim=Math.max(0,+cfg.dim_seconds_before||15);if(!cfg.enabled)return;state.idle=setTimeout(()=>showSaver('Toimettomuus '+delay+' s'),delay*1000);if(dim&&delay>dim)state.dim=setTimeout(()=>api('/action',{action:'brightness',value:Math.max(8,(state.status?.brightness||60)*.45|0)}).catch(()=>{}),(delay-dim)*1000)}
function idleLabel(){const e=$('#n98-next');if(e)e.textContent='ajastin aktiivinen'}
function applyMode(){const p=state.status?.profile;document.body.classList.toggle('n98-lite',p==='maintenance'||p==='saver')}
async function refresh(){try{const r=await api('/status');if(!r.version)throw Error('Virheellinen vastaus');state.status=r;const pill=$('#n98-pill'),cpu=+r.cpu_percent||0;pill.textContent='Kuorma '+Math.round(cpu)+'%';pill.classList.toggle('warn',cpu>=65&&cpu<85);pill.classList.toggle('bad',cpu>=85);applyMode();idleLabel();const panel=$('#n98-panel');if(panel&&!panel.classList.contains('n98-hidden'))renderPanel();const sec=r.config?.profiles?.[r.profile]?.metric_seconds||7;clearTimeout(state.timer);state.timer=setTimeout(refresh,Math.max(4,sec)*1000)}catch(err){const p=$('#n98-pill');p.textContent='Kuorma ?';p.classList.add('bad');clearTimeout(state.timer);state.timer=setTimeout(refresh,12000)}}
function critical(err){const text=String(err?.message||err||'');if(!/(render|router|app-grid|home|nspire)/i.test(text))return;const now=Date.now(),arr=JSON.parse(localStorage.getItem('n98-errors')||'[]').filter(x=>now-x<120000);arr.push(now);localStorage.setItem('n98-errors',JSON.stringify(arr));if(arr.length>=3)showSafe(text)}
function showSafe(reason){let e=add('n98-safe');e.innerHTML=`<div class="n98-head"><h2>Turvatila</h2></div><p>Käyttöliittymässä havaittiin kolme kriittistä virhettä.</p><div class="n98-log">${esc(reason)}</div><div class="n98-actions"><button data-safe="repair">Palauta etusivu</button><button data-safe="restart">Käynnistä UI</button><button data-safe="backup">Tee varmuuskopio</button><button data-safe="close">Jatka normaalisti</button></div>`;e.onclick=x=>{const a=x.target.dataset.safe;if(a==='repair'){repairHome(true);goHome();e.remove()}if(a==='restart')act('restart');if(a==='backup')act('backup');if(a==='close'){localStorage.removeItem('n98-errors');e.remove()}};notify('Turvatila avattiin: '+reason,'safe-mode')}
function observe(){let scheduled=false;new MutationObserver(()=>{if(scheduled)return;scheduled=true;setTimeout(()=>{scheduled=false;repairHome();updateScroll()},500)}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class','hidden']});addEventListener('popstate',()=>setTimeout(()=>repairHome(true),80));addEventListener('hashchange',()=>setTimeout(()=>repairHome(true),80));addEventListener('scroll',updateScroll,true)}
function boot(){shell();repairHome(true);observe();refresh();resetIdle();['pointerdown','keydown','wheel','touchstart'].forEach(n=>addEventListener(n,()=>{hideSaver();resetIdle()},{passive:true,capture:true}));addEventListener('error',e=>critical(e.error||e.message));addEventListener('unhandledrejection',e=>critical(e.reason));setInterval(updateScroll,2500);notify('V9.8 käyttöliittymäkerros käynnistyi','boot')}
document.readyState==='loading'?document.addEventListener('DOMContentLoaded',boot,{once:true}):boot();
})();
JS

if command -v node >/dev/null 2>&1; then
  node --check "$ASSET_ROOT/nspire98.js" || die "Käyttöliittymäkerroksen JavaScript-tarkistus epäonnistui"
fi

# Lisää resurssit vain kerran.
python3 - "$INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text(encoding='utf-8',errors='replace')
css='<link id="nspire98-css" rel="stylesheet" href="nspire98/nspire98.css?v=9.8.0">'
js='<script id="nspire98-js" defer src="nspire98/nspire98.js?v=9.8.0"></script>'
if 'id="nspire98-css"' not in text:
    text=text.replace('</head>',css+'\n'+js+'\n</head>') if '</head>' in text else css+'\n'+js+'\n'+text
else:
    import re
    text=re.sub(r'<link id="nspire98-css"[^>]*>',css,text)
    text=re.sub(r'<script id="nspire98-js"[^>]*></script>',js,text)
p.write_text(text,encoding='utf-8')
PY

grep -q 'id="nspire98-js"' "$INDEX" || die "Käyttöliittymäresurssin lisäys epäonnistui"

# -----------------------------------------------------------------------------
# Systemd-palvelut ja ajastimet
# -----------------------------------------------------------------------------

cat > /etc/systemd/system/nspire-v98-api.service <<'UNIT'
[Unit]
Description=NSPIRE V9.8 local maintenance API
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/nspire-v98/nspire98.py daemon
Restart=on-failure
RestartSec=4
Nice=5
CPUWeight=100
IOWeight=100
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/nspire-v98-watchdog.service <<'UNIT'
[Unit]
Description=NSPIRE V9.8 bounded watchdog
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/nspire-v98/nspire98.py watchdog
Nice=15
CPUWeight=10
IOWeight=10
UNIT
cat > /etc/systemd/system/nspire-v98-watchdog.timer <<'UNIT'
[Unit]
Description=NSPIRE V9.8 watchdog timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=15s
[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/nspire-v98-power.service <<'UNIT'
[Unit]
Description=NSPIRE V9.8 automatic power profile
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/nspire-v98/nspire98.py power
Nice=12
UNIT
cat > /etc/systemd/system/nspire-v98-power.timer <<'UNIT'
[Unit]
Description=NSPIRE V9.8 automatic power timer
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/nspire-v98-stability.service <<'UNIT'
[Unit]
Description=NSPIRE V9.8 stability sampler
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/nspire-v98/nspire98.py sample
Nice=18
CPUWeight=5
IOWeight=5
UNIT
cat > /etc/systemd/system/nspire-v98-stability.timer <<'UNIT'
[Unit]
Description=NSPIRE V9.8 24 hour stability sampling
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/nspire-v98-backup.service <<'UNIT'
[Unit]
Description=NSPIRE V9.8 settings backup
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/nspire-v98/nspire98.py backup
Nice=18
CPUWeight=5
IOWeight=5
UNIT
cat > /etc/systemd/system/nspire-v98-backup.timer <<'UNIT'
[Unit]
Description=NSPIRE V9.8 daily backup
[Timer]
OnBootSec=15min
OnCalendar=daily
Persistent=true
RandomizedDelaySec=10min
[Install]
WantedBy=timers.target
UNIT

# Vanhat päällekkäiset kokeilu-watchdogit pois, mutta niiden tiedostoja ei poisteta.
systemctl disable --now nspire-health-watchdog.timer 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now nspire-v98-api.service
systemctl enable --now nspire-v98-watchdog.timer nspire-v98-power.timer nspire-v98-stability.timer nspire-v98-backup.timer

# -----------------------------------------------------------------------------
# Komennot: tila, diagnostiikka, turvallinen restart ja palautus
# -----------------------------------------------------------------------------

cat > /usr/local/bin/nspire-status <<'SH'
#!/usr/bin/env bash
exec python3 /opt/nspire-v98/nspire98.py status
SH
cat > /usr/local/bin/nspire-diagnostics <<'SH'
#!/usr/bin/env bash
exec python3 /opt/nspire-v98/nspire98.py diagnostics
SH
cat > /usr/local/bin/nspire-safe-restart <<'SH'
#!/usr/bin/env bash
exec python3 /opt/nspire-v98/nspire98.py restart
SH
cat > /usr/local/bin/nspire-backup-settings <<'SH'
#!/usr/bin/env bash
exec python3 /opt/nspire-v98/nspire98.py backup
SH

cat > /usr/local/bin/nspire-v98-restore <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Aja sudo-komennolla"; exit 1; }
ROOT=/var/lib/nspire-v98
BACKUP="${1:-$(cat "$ROOT/last-backup.txt" 2>/dev/null || true)}"
[[ -n "$BACKUP" && -d "$BACKUP" ]] || { echo "Palautettavaa varmuuskopiota ei löytynyt"; exit 1; }
INDEX="$(cat "$BACKUP/index-path.txt")"
cp -a "$BACKUP/files/index.html" "$INDEX"
WEB="$(dirname "$INDEX")"
rm -rf "$WEB/nspire98"
[[ -d "$BACKUP/files/nspire98.old" ]] && cp -a "$BACKUP/files/nspire98.old" "$WEB/nspire98"
systemctl disable --now nspire-v98-api.service nspire-v98-watchdog.timer nspire-v98-power.timer nspire-v98-stability.timer nspire-v98-backup.timer 2>/dev/null || true
systemctl daemon-reload
while read -r service; do [[ -n "$service" ]] && systemctl restart "$service" || true; done < "$ROOT/services.txt"
echo "Palautus valmis: $BACKUP"
SH
chmod 755 /usr/local/bin/nspire-status /usr/local/bin/nspire-diagnostics /usr/local/bin/nspire-safe-restart /usr/local/bin/nspire-backup-settings /usr/local/bin/nspire-v98-restore

cat > /etc/nspire-v98/CHANGELOG.txt <<'TXT'
NSPIRE V9.8.0 ALL IN ONE

- Pika-asetuspaneeli yläpalkista
- Kuorma, RAM, CPU-lämpö, akku, kirkkaus ja aktiivinen virtaprofiili
- Automaattinen Teho latauksessa ja Ylläpito akulla
- Erillinen käsin valittava Säästö
- Kaikkien profiilien arvot muokattavassa JSON-asetustiedostossa
- BME680 jätetään aina käyttöön
- Yksi tapahtumapohjainen näytönsäästäjäajastin ja toimiva varanäytönsäästäjä
- Sofa/Sohva 2 -tekstien boldaus poistettu
- Näytön himmennys ennen säästäjää ja näyttö pois -painike
- 6 x 5 -etusivuruudukko
- Kansiot ensin, sovellukset aakkosjärjestyksessä
- Kansioitujen ja muiden päällekkäisten sovellusten piilotus
- Asetukset-kansio etusivulle
- Etusivun automaattinen palautus sovelluksesta palattaessa
- Yhtenäinen takaisin/koti-painike ja pitkä painallus etusivulle
- Yleiset vierityspainikkeet kaikissa vieritettävissä näkymissä
- Pi Zero 2 W -kevyt tila ilman animaatioita Ylläpito- ja Säästö-profiileissa
- Rajattu watchdog: 3 virhettä, vähintään 5 minuutin restart-jäähy
- Automaattinen turvatila kolmen kriittisen käyttöliittymävirheen jälkeen
- Päivittäinen varmuuskopio ja 12 viimeisimmän säilytys
- Yhden painalluksen diagnostiikka, varmuuskopio ja turvallinen UI-restart
- 24 tunnin vakaustestin näytteenotto 5 minuutin välein
- Asennuksen esitarkistus, syntaksitarkistus, varmuuskopio ja health-tarkistus
TXT

# -----------------------------------------------------------------------------
# Lopputarkistus ja automaattinen rollback
# -----------------------------------------------------------------------------

rollback(){
  log "Lopputarkistus epäonnistui – palautetaan edellinen käyttöliittymä"
  /usr/local/bin/nspire-v98-restore "$BACKUP" || true
}
trap rollback ERR

sleep 2
curl -fsS --max-time 4 http://127.0.0.1:8770/api/status >/tmp/nspire-v98-status.json
python3 - <<'PY'
import json
x=json.load(open('/tmp/nspire-v98-status.json'))
assert x.get('version')=='9.8.0',x
assert 'cpu_percent' in x and 'services' in x,x
print('Hallintapalvelu OK – kuorma',x['cpu_percent'],'%')
PY

grep -q 'nspire98.js?v=9.8.0' "$INDEX"
[[ -s "$ASSET_ROOT/nspire98.js" && -s "$ASSET_ROOT/nspire98.css" ]]

# Käynnistä nykyinen UI kerran uudelleen, jotta resurssi latautuu.
python3 "$INSTALL_ROOT/nspire98.py" restart >/dev/null 2>&1 || true

trap - ERR
log "NSPIRE V${VERSION} asennettu onnistuneesti"
echo
echo "Komennot:"
echo "  nspire-status"
echo "  nspire-diagnostics"
echo "  sudo nspire-safe-restart"
echo "  sudo nspire-backup-settings"
echo "  sudo nspire-v98-restore"
echo
echo "Asetustiedosto: $CONFIG_FILE"
echo "Varmuuskopio: $BACKUP"
echo "Valmis. Anna käyttöliittymälle 15–25 sekuntia käynnistyä."
