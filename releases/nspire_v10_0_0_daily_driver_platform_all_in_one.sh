#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="10.0.0"
APP_ROOT="/opt/nspire-v10"
STAGE_ROOT="/opt/nspire-v10.stage"
DATA_ROOT="/var/lib/nspire-v10"
CONF_ROOT="/etc/nspire-v10"
CONFIG_FILE="$CONF_ROOT/config.json"
BACKUP_ROOT="/var/backups/nspire-v10"
PORT="8775"
MODE="update"
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/pre-v10-$STAMP"
ACTIVATED=0

[[ "${1:-}" == "--clean" ]] && MODE="clean"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; logger -t nspire-v10-installer -- "$*" 2>/dev/null || true; }
die(){ printf '\nVIRHE: %s\n' "$*" >&2; exit 1; }

rollback_on_error(){
  rc=$?
  trap - ERR
  echo
  echo "Asennus epäonnistui (koodi $rc). Palautetaan aiempi kioskikäynnistys."
  if [[ -x /usr/local/sbin/nspire-v10-rollback ]]; then
    /usr/local/sbin/nspire-v10-rollback --installer-failure || true
  fi
  exit "$rc"
}
trap rollback_on_error ERR

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Aja sudo-komennolla: sudo bash $SELF"
command -v python3 >/dev/null || die "python3 puuttuu"
command -v systemctl >/dev/null || die "systemd puuttuu"
command -v curl >/dev/null || die "curl puuttuu"
command -v tar >/dev/null || die "tar puuttuu"

FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
[[ "${FREE_KB:-0}" -ge 220000 ]] || die "Vapaata levytilaa tarvitaan vähintään 220 Mt"

log "NSPIRE V${VERSION} DAILY DRIVER PLATFORM"
log "Asennustila: $MODE"

mkdir -p "$DATA_ROOT" "$CONF_ROOT" "$BACKUP_ROOT" "$BACKUP/files"
chmod 755 "$DATA_ROOT" "$CONF_ROOT" "$BACKUP_ROOT"

# -----------------------------------------------------------------------------
# Tallenna nykyinen järjestelmä ja kioskien tila ennen muutoksia.
# Vanhaa nspire-ui-palvelua ei poisteta: V10 käyttää sitä legacy/BME-lähteenä.
# -----------------------------------------------------------------------------

log "Varmuuskopioidaan nykyinen tila"
for path in \
  "$APP_ROOT" "$CONF_ROOT" "$DATA_ROOT" \
  /opt/nspire-v98 /etc/nspire-v98 /var/lib/nspire-v98 \
  /etc/systemd/system/nspire-v10.service \
  /etc/systemd/system/nspire-v10-kiosk.service \
  /etc/systemd/system/nspire-v10-healthcheck.service \
  /etc/systemd/system/nspire-v10-healthcheck.timer \
  /usr/local/bin/nspire-v10-kiosk \
  /usr/local/sbin/nspire-v10-rollback
 do
  if [[ -e "$path" ]]; then
    dest="$BACKUP/files${path}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$path" "$dest"
  fi
done

STATE_FILE="$BACKUP/previous-services.env"
: > "$STATE_FILE"
for service in kiosk-cog.service nspire-kiosk.service fb1-desktop.service nspire-ui.service nspire-v4.service; do
  if systemctl cat "$service" >/dev/null 2>&1; then
    enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
    active="$(systemctl is-active "$service" 2>/dev/null || true)"
    printf '%s|%s|%s\n' "$service" "$enabled" "$active" >> "$STATE_FILE"
    systemctl cat "$service" > "$BACKUP/${service}.unit" 2>/dev/null || true
  fi
done
printf '%s\n' "$BACKUP" > "$DATA_ROOT/last-install-backup.txt"
cp -a "$STATE_FILE" "$DATA_ROOT/previous-services.env"

if [[ "$MODE" == "clean" && -f "$CONFIG_FILE" ]]; then
  cp -a "$CONFIG_FILE" "$BACKUP/config-before-clean.json"
  rm -f "$CONFIG_FILE"
fi

rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT/static"

# -----------------------------------------------------------------------------
# Oletusasetukset. BME680 on aina päällä eikä profiilikoodi sammuta sensoripalvelua.
# -----------------------------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
cat > "$CONFIG_FILE" <<'JSON'
{
  "version": "10.0.0",
  "manual_profile": "auto",
  "bme_always_on": true,
  "ui": {
    "animations": false,
    "status_seconds": 4,
    "grid_columns": 6,
    "grid_rows": 5,
    "theme": "dark"
  },
  "screensaver": {
    "enabled": true,
    "delay_seconds": 120,
    "dim_seconds_before": 15,
    "profile": "sofa2",
    "sleep_green_from": "07:00",
    "sleep_yellow_from": "19:30",
    "sleep_red_from": "20:00"
  },
  "profiles": {
    "performance": {
      "label": "Teho",
      "governor": "performance",
      "max_cpu_percent": 100,
      "brightness": 100,
      "status_seconds": 4,
      "screensaver_seconds": 180,
      "wifi": true,
      "vnc": true,
      "camera": true,
      "animations": false
    },
    "maintenance": {
      "label": "Ylläpito",
      "governor": "ondemand",
      "max_cpu_percent": 75,
      "brightness": 65,
      "status_seconds": 7,
      "screensaver_seconds": 120,
      "wifi": true,
      "vnc": true,
      "camera": true,
      "animations": false
    },
    "saver": {
      "label": "Säästö",
      "governor": "powersave",
      "max_cpu_percent": 45,
      "brightness": 25,
      "status_seconds": 12,
      "screensaver_seconds": 45,
      "wifi": true,
      "vnc": false,
      "camera": false,
      "animations": false
    }
  }
}
JSON
fi
chmod 644 "$CONFIG_FILE"

# -----------------------------------------------------------------------------
# V10 backend: yksi kevyt palvelu, välimuistitettu status, rajatut huoltotoiminnot.
# -----------------------------------------------------------------------------

cat > "$STAGE_ROOT/backend.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import mimetypes
import os
import shutil
import subprocess
import tarfile
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

VERSION = "10.0.0"
APP = Path("/opt/nspire-v10")
STATIC = APP / "static"
DATA = Path("/var/lib/nspire-v10")
CONF = Path("/etc/nspire-v10/config.json")
BACKUPS = Path("/var/backups/nspire-v10")
EVENTS = DATA / "events.jsonl"
HEALTH_STATE = DATA / "healthcheck.json"
SAFE_MODE = DATA / "safe-mode"
CALCS = DATA / "saved-calculations.jsonl"
PORT = int(os.environ.get("NSPIRE_V10_PORT", "8775"))
LEGACY_PORTS = [8765, 8093, 8081, 8770]

DATA.mkdir(parents=True, exist_ok=True)
BACKUPS.mkdir(parents=True, exist_ok=True)

DEFAULTS: dict[str, Any] = {
    "version": VERSION,
    "manual_profile": "auto",
    "bme_always_on": True,
    "ui": {"animations": False, "status_seconds": 4, "grid_columns": 6, "grid_rows": 5, "theme": "dark"},
    "screensaver": {
        "enabled": True, "delay_seconds": 120, "dim_seconds_before": 15, "profile": "sofa2",
        "sleep_green_from": "07:00", "sleep_yellow_from": "19:30", "sleep_red_from": "20:00"
    },
    "profiles": {
        "performance": {"label":"Teho","governor":"performance","max_cpu_percent":100,"brightness":100,"status_seconds":4,"screensaver_seconds":180,"wifi":True,"vnc":True,"camera":True,"animations":False},
        "maintenance": {"label":"Ylläpito","governor":"ondemand","max_cpu_percent":75,"brightness":65,"status_seconds":7,"screensaver_seconds":120,"wifi":True,"vnc":True,"camera":True,"animations":False},
        "saver": {"label":"Säästö","governor":"powersave","max_cpu_percent":45,"brightness":25,"status_seconds":12,"screensaver_seconds":45,"wifi":True,"vnc":False,"camera":False,"animations":False}
    }
}

LOCK = threading.RLock()
STATUS_CACHE: dict[str, Any] = {"time": 0.0, "value": {}}
CPU_PREV: tuple[int, int] | None = None
ACTIVE_PROFILE = "unknown"
LAST_PROFILE_APPLY = 0.0


def run(cmd: list[str], timeout: int = 20) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout, check=False)
    except Exception as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def atomic_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def deep_merge(base: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    out = json.loads(json.dumps(base))
    for key, value in incoming.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def config() -> dict[str, Any]:
    current = read_json(CONF, {})
    merged = deep_merge(DEFAULTS, current if isinstance(current, dict) else {})
    merged["version"] = VERSION
    merged["bme_always_on"] = True
    return merged


def save_config(value: dict[str, Any]) -> dict[str, Any]:
    merged = deep_merge(config(), value)
    merged["version"] = VERSION
    merged["bme_always_on"] = True
    atomic_json(CONF, merged)
    return merged


def event(kind: str, message: str, **extra: Any) -> None:
    row = {"time": int(time.time()), "kind": kind, "message": message, **extra}
    with LOCK:
        with EVENTS.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        try:
            lines = EVENTS.read_text(encoding="utf-8").splitlines()
            if len(lines) > 800:
                EVENTS.write_text("\n".join(lines[-600:]) + "\n", encoding="utf-8")
        except Exception:
            pass


def recent_events(limit: int = 60) -> list[dict[str, Any]]:
    try:
        lines = deque(EVENTS.read_text(encoding="utf-8").splitlines(), maxlen=limit)
        return [json.loads(line) for line in lines if line.strip()]
    except Exception:
        return []


def cpu_snapshot() -> tuple[int, int]:
    vals = [int(x) for x in Path("/proc/stat").read_text().splitlines()[0].split()[1:]]
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    return sum(vals), idle


def cpu_percent() -> float:
    global CPU_PREV
    current = cpu_snapshot()
    if CPU_PREV is None:
        CPU_PREV = current
        return 0.0
    total = max(1, current[0] - CPU_PREV[0])
    idle = max(0, current[1] - CPU_PREV[1])
    CPU_PREV = current
    return round(100.0 * (total - idle) / total, 1)


def temperature() -> float | None:
    for path in [Path("/sys/class/thermal/thermal_zone0/temp")]:
        try:
            return round(int(path.read_text().strip()) / 1000, 1)
        except Exception:
            pass
    return None


def frequency_mhz() -> int | None:
    values = []
    for path in Path("/sys/devices/system/cpu").glob("cpu*/cpufreq/scaling_cur_freq"):
        try:
            values.append(int(path.read_text().strip()) // 1000)
        except Exception:
            pass
    return round(sum(values) / len(values)) if values else None


def memory() -> dict[str, float]:
    info: dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, val = line.split(":", 1)
            info[key] = int(val.strip().split()[0])
    except Exception:
        return {"ram_percent": 0.0, "ram_mb": 0.0, "swap_percent": 0.0}
    total = max(1, info.get("MemTotal", 1)); available = info.get("MemAvailable", 0)
    swap_total = info.get("SwapTotal", 0); swap_free = info.get("SwapFree", 0)
    return {
        "ram_percent": round(100 * (total - available) / total, 1),
        "ram_mb": round((total - available) / 1024, 1),
        "swap_percent": round(100 * (swap_total - swap_free) / swap_total, 1) if swap_total else 0.0,
    }


def http_json(port: int, path: str, timeout: float = 0.8) -> Any:
    if port == PORT:
        return None
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers={"User-Agent": "NSPIRE-V10"})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            if response.status >= 400:
                return None
            return json.loads(response.read(512000).decode("utf-8", "replace"))
    except Exception:
        return None


def legacy_probe(paths: list[str]) -> dict[str, Any]:
    for port in LEGACY_PORTS:
        for path in paths:
            value = http_json(port, path)
            if isinstance(value, dict):
                return {"ok": True, "port": port, "path": path, "data": value}
    return {"ok": False, "data": {}}


def battery() -> dict[str, Any]:
    result: dict[str, Any] = {"percent": None, "charging": None, "status": "unknown", "source": "none"}
    power = Path("/sys/class/power_supply")
    if power.exists():
        for base in power.glob("*"):
            try:
                cap = int((base / "capacity").read_text()) if (base / "capacity").exists() else None
                stat = (base / "status").read_text().strip().lower() if (base / "status").exists() else ""
                if cap is not None or stat:
                    return {"percent": cap, "charging": stat in {"charging", "full", "not charging"},
                            "status": stat or "unknown", "source": str(base)}
            except Exception:
                pass
    legacy = legacy_probe(["/api/status", "/status", "/api/battery", "/battery"])
    data = legacy.get("data", {})
    candidates = [data.get("battery"), data.get("power"), data]
    for item in candidates:
        if isinstance(item, dict):
            cap = item.get("percent", item.get("capacity", item.get("battery_percent")))
            charging = item.get("charging")
            if cap is not None or charging is not None:
                try: cap = int(round(float(cap))) if cap is not None else None
                except Exception: cap = None
                return {"percent": cap, "charging": charging, "status": item.get("status", "legacy"),
                        "source": f"legacy:{legacy.get('port')}"}
    return result


def brightness_paths() -> list[tuple[Path, Path]]:
    result = []
    root = Path("/sys/class/backlight")
    if root.exists():
        for base in root.glob("*"):
            if (base / "brightness").exists() and (base / "max_brightness").exists():
                result.append((base / "brightness", base / "max_brightness"))
    return result


def get_brightness() -> int | None:
    for current, maximum in brightness_paths():
        try:
            return round(100 * int(current.read_text()) / max(1, int(maximum.read_text())))
        except Exception:
            pass
    return None


def set_brightness(percent: int) -> bool:
    changed = False
    percent = max(1, min(100, int(percent)))
    for current, maximum in brightness_paths():
        try:
            max_value = int(maximum.read_text())
            current.write_text(str(max(1, round(max_value * percent / 100))))
            changed = True
        except Exception:
            pass
    event("display", f"Kirkkaus {percent}%", success=changed)
    return changed


def wifi_info() -> dict[str, Any]:
    ssid = run(["iwgetid", "-r"], 4).stdout.strip() if shutil.which("iwgetid") else ""
    if not ssid and shutil.which("nmcli"):
        out = run(["nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL", "dev", "wifi"], 6).stdout
        for line in out.splitlines():
            if line.startswith("yes:"):
                parts = line.split(":")
                ssid = parts[1] if len(parts) > 1 else ""
                signal = parts[2] if len(parts) > 2 else None
                return {"connected": True, "ssid": ssid, "signal": signal}
    return {"connected": bool(ssid), "ssid": ssid, "signal": None}


def set_wifi(enabled: bool) -> bool:
    if not shutil.which("nmcli"):
        return False
    ok = run(["nmcli", "radio", "wifi", "on" if enabled else "off"], 15).returncode == 0
    event("network", "Wi-Fi päälle" if enabled else "Wi-Fi pois", success=ok)
    return ok


def set_vnc(enabled: bool) -> list[str]:
    changed = []
    for service in ["vncserver-x11-serviced.service", "x11vnc.service", "wayvnc.service"]:
        if run(["systemctl", "cat", service], 5).returncode == 0:
            run(["systemctl", "enable" if enabled else "disable", "--now", service], 25)
            changed.append(service)
    event("network", "VNC päälle" if enabled else "VNC pois", services=changed)
    return changed


def set_governor(governor: str, max_cpu_percent: int) -> None:
    max_cpu_percent = max(30, min(100, int(max_cpu_percent)))
    for policy in Path("/sys/devices/system/cpu/cpufreq").glob("policy*"):
        try:
            available = (policy / "scaling_available_governors").read_text().split()
            chosen = governor if governor in available else ("ondemand" if "ondemand" in available else available[0])
            (policy / "scaling_governor").write_text(chosen)
        except Exception:
            pass
        try:
            cpu_max = int((policy / "cpuinfo_max_freq").read_text())
            cpu_min = int((policy / "cpuinfo_min_freq").read_text())
            target = max(cpu_min, round(cpu_max * max_cpu_percent / 100))
            (policy / "scaling_max_freq").write_text(str(target))
        except Exception:
            pass


def desired_profile() -> str:
    cfg = config(); manual = str(cfg.get("manual_profile", "auto"))
    if manual in {"performance", "maintenance", "saver"}:
        return manual
    return "performance" if battery().get("charging") is not False else "maintenance"


def apply_profile(requested: str, force: bool = False) -> dict[str, Any]:
    global ACTIVE_PROFILE, LAST_PROFILE_APPLY
    cfg = config()
    if requested not in {"auto", "performance", "maintenance", "saver"}:
        raise ValueError("Tuntematon virtaprofiili")
    if requested == "auto":
        cfg["manual_profile"] = "auto"
        actual = "performance" if battery().get("charging") is not False else "maintenance"
    else:
        cfg["manual_profile"] = requested
        actual = requested
    profile = cfg.get("profiles", {}).get(actual)
    if not isinstance(profile, dict):
        raise ValueError("Virtaprofiilin asetukset puuttuvat")
    if not force and ACTIVE_PROFILE == actual:
        return {"requested": requested, "profile": actual, "settings": profile, "changed": False}
    set_governor(str(profile.get("governor", "ondemand")), int(profile.get("max_cpu_percent", 75)))
    set_brightness(int(profile.get("brightness", 60)))
    set_wifi(bool(profile.get("wifi", True)))
    set_vnc(bool(profile.get("vnc", True)))
    atomic_json(DATA / "camera-policy.json", {"enabled": bool(profile.get("camera", True)), "time": int(time.time())})
    cfg.setdefault("screensaver", {})["delay_seconds"] = int(profile.get("screensaver_seconds", cfg["screensaver"].get("delay_seconds", 120)))
    cfg.setdefault("ui", {})["animations"] = bool(profile.get("animations", False))
    save_config(cfg)
    ACTIVE_PROFILE = actual; LAST_PROFILE_APPLY = time.time()
    atomic_json(DATA / "active-profile.json", {"requested": requested, "profile": actual, "time": int(time.time())})
    event("power", f"Virtaprofiili {actual}")
    return {"requested": requested, "profile": actual, "settings": profile, "changed": True}


def profile_loop() -> None:
    global ACTIVE_PROFILE
    while True:
        try:
            wanted = desired_profile()
            if wanted != ACTIVE_PROFILE:
                manual = str(config().get("manual_profile", "auto"))
                apply_profile(manual, force=True)
        except Exception as exc:
            event("error", "Virtaprofiilin automatiikka epäonnistui", error=str(exc))
        time.sleep(30)


def service_state(name: str) -> dict[str, Any]:
    exists = run(["systemctl", "cat", name], 5).returncode == 0
    active = run(["systemctl", "is-active", "--quiet", name], 5).returncode == 0 if exists else False
    enabled = run(["systemctl", "is-enabled", "--quiet", name], 5).returncode == 0 if exists else False
    return {"name": name, "exists": exists, "active": active, "enabled": enabled}


def top_processes() -> list[dict[str, Any]]:
    result = run(["ps", "-eo", "pid,comm,%cpu,%mem,nice", "--sort=-%cpu"], 5)
    rows = []
    for line in result.stdout.splitlines()[1:9]:
        parts = line.split(None, 4)
        if len(parts) == 5:
            try:
                rows.append({"pid": int(parts[0]), "name": parts[1], "cpu": float(parts[2]),
                             "memory": float(parts[3]), "nice": int(parts[4])})
            except Exception:
                pass
    return rows


def status(force: bool = False) -> dict[str, Any]:
    now = time.time()
    with LOCK:
        if not force and now - float(STATUS_CACHE.get("time", 0)) < 2.5:
            return STATUS_CACHE["value"]
        mem = memory(); batt = battery(); cfg = config()
        value = {
            "ok": True, "version": VERSION, "time": int(now), "uptime_seconds": int(float(Path("/proc/uptime").read_text().split()[0])),
            "cpu_percent": cpu_percent(), "temperature_c": temperature(), "frequency_mhz": frequency_mhz(),
            **mem, "battery": batt, "brightness": get_brightness(), "profile": ACTIVE_PROFILE,
            "requested_profile": cfg.get("manual_profile", "auto"), "wifi": wifi_info(),
            "safe_mode": SAFE_MODE.exists(), "healthcheck": read_json(HEALTH_STATE, {}),
            "services": [service_state(x) for x in ["nspire-v10.service", "nspire-v10-kiosk.service", "nspire-ui.service", "nspire-v4.service"]],
            "top_processes": top_processes(), "events": recent_events(), "config": cfg,
        }
        STATUS_CACHE["time"] = now; STATUS_CACHE["value"] = value
        return value


def make_backup(label: str = "manual") -> str:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output = BACKUPS / f"{label}-{stamp}.tar.gz"
    paths = [APP, DATA, Path("/etc/nspire-v10"), Path("/etc/systemd/system/nspire-v10.service"),
             Path("/etc/systemd/system/nspire-v10-kiosk.service")]
    with tarfile.open(output, "w:gz") as archive:
        for path in paths:
            if path.exists():
                archive.add(path, arcname=str(path).lstrip("/"), recursive=True)
    files = sorted(BACKUPS.glob("*.tar.gz"), key=lambda p: p.stat().st_mtime, reverse=True)
    for old in files[12:]:
        try: old.unlink()
        except Exception: pass
    event("backup", "Varmuuskopio luotu", path=str(output))
    return str(output)


def diagnostics() -> str:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out = Path("/home/mavks") / f"nspire-v10-diagnostics-{stamp}.txt"
    sections = [
        ("STATUS", json.dumps(status(True), ensure_ascii=False, indent=2)),
        ("UPTIME", run(["uptime"], 5).stdout),
        ("MEMORY", run(["free", "-h"], 5).stdout),
        ("DISK", run(["df", "-h", "/"], 5).stdout),
        ("JOURNAL", run(["journalctl", "--no-pager", "-n", "400", "-u", "nspire-v10.service", "-u", "nspire-v10-kiosk.service", "-u", "nspire-v10-healthcheck.service"], 20).stdout),
    ]
    out.write_text("\n\n".join(f"===== {title} =====\n{text}" for title, text in sections), encoding="utf-8")
    try: shutil.chown(out, user="mavks", group="mavks")
    except Exception: pass
    event("diagnostics", "Diagnostiikkaraportti luotu", path=str(out))
    return str(out)


def schedule_command(command: list[str]) -> bool:
    if shutil.which("systemd-run"):
        return run(["systemd-run", "--unit", f"nspire-v10-action-{int(time.time())}", "--on-active=2s", *command], 8).returncode == 0
    subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


def save_calculation(payload: dict[str, Any]) -> bool:
    row = {"time": int(time.time()), **payload}
    with CALCS.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    lines = CALCS.read_text(encoding="utf-8").splitlines()
    if len(lines) > 300:
        CALCS.write_text("\n".join(lines[-250:]) + "\n", encoding="utf-8")
    return True


def static_bytes(path: Path) -> tuple[bytes, str]:
    data = path.read_bytes()
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    return data, mime


class Handler(BaseHTTPRequestHandler):
    server_version = "NSPIRE-V10"

    def send_bytes(self, data: bytes, mime: str, status_code: int = 200, cache: str = "no-store") -> None:
        self.send_response(status_code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, payload: Any, status_code: int = 200) -> None:
        self.send_bytes(json.dumps(payload, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8", status_code)

    def body_json(self) -> dict[str, Any]:
        length = min(1024 * 1024, int(self.headers.get("Content-Length", "0") or 0))
        raw = self.rfile.read(length) if length else b"{}"
        value = json.loads(raw.decode("utf-8") or "{}")
        return value if isinstance(value, dict) else {}

    def do_GET(self) -> None:
        parsed = urlparse(self.path); path = parsed.path
        try:
            if path == "/api/health":
                self.send_json({"ok": True, "version": VERSION, "safe_mode": SAFE_MODE.exists()}); return
            if path == "/api/status":
                self.send_json(status()); return
            if path == "/api/config":
                self.send_json(config()); return
            if path == "/api/events":
                self.send_json({"ok": True, "events": recent_events(120)}); return
            if path == "/api/sensors":
                self.send_json(legacy_probe(["/api/sensors", "/api/bme", "/sensors", "/bme", "/api/status"])); return
            if path == "/api/weather":
                self.send_json(legacy_probe(["/api/weather", "/weather", "/api/status"])); return
            if path == "/api/stability":
                self.send_json({"ok": True, "healthcheck": read_json(HEALTH_STATE, {}), "events": recent_events(200)}); return
            if path == "/api/calculations":
                rows = []
                if CALCS.exists():
                    for line in deque(CALCS.read_text(encoding="utf-8").splitlines(), maxlen=100):
                        try: rows.append(json.loads(line))
                        except Exception: pass
                self.send_json({"ok": True, "calculations": rows}); return
            if path == "/" or path == "/index.html":
                page = STATIC / ("safe.html" if SAFE_MODE.exists() else "index.html")
                data, mime = static_bytes(page); self.send_bytes(data, mime); return
            if path.startswith("/static/"):
                relative = Path(path.removeprefix("/static/"))
                if ".." in relative.parts:
                    self.send_json({"ok": False, "error": "Virheellinen polku"}, 400); return
                target = STATIC / relative
                if target.is_file():
                    data, mime = static_bytes(target); self.send_bytes(data, mime, cache="public, max-age=3600"); return
            self.send_json({"ok": False, "error": "Ei löytynyt"}, 404)
        except Exception as exc:
            event("error", "GET epäonnistui", path=path, error=str(exc))
            self.send_json({"ok": False, "error": str(exc)}, 500)

    def do_POST(self) -> None:
        if urlparse(self.path).path != "/api/action":
            self.send_json({"ok": False, "error": "Ei löytynyt"}, 404); return
        try:
            data = self.body_json(); action = str(data.get("action", ""))
            if action == "profile":
                result = apply_profile(str(data.get("profile", "auto")), force=True)
            elif action == "config":
                patch = data.get("patch") if isinstance(data.get("patch"), dict) else {}
                result = save_config(patch)
            elif action == "brightness":
                result = set_brightness(int(data.get("value", 60)))
            elif action == "wifi":
                result = set_wifi(bool(data.get("enabled", True)))
            elif action == "vnc":
                result = set_vnc(bool(data.get("enabled", True)))
            elif action == "backup":
                result = make_backup()
            elif action == "diagnostics":
                result = diagnostics()
            elif action == "restart_ui":
                result = schedule_command(["systemctl", "restart", "nspire-v10-kiosk.service"])
            elif action == "restart_all":
                result = schedule_command(["systemctl", "restart", "nspire-v10.service", "nspire-v10-kiosk.service"])
            elif action == "rollback":
                result = schedule_command(["/usr/local/sbin/nspire-v10-rollback"])
            elif action == "safe_mode":
                enabled = bool(data.get("enabled", True))
                if enabled: SAFE_MODE.touch()
                else: SAFE_MODE.unlink(missing_ok=True)
                event("safe", "Turvatila päälle" if enabled else "Turvatila pois")
                result = schedule_command(["systemctl", "restart", "nspire-v10-kiosk.service"])
            elif action == "event":
                event(str(data.get("kind", "ui")), str(data.get("message", "")), detail=data.get("detail")); result = True
            elif action == "save_calculation":
                result = save_calculation(data.get("calculation") if isinstance(data.get("calculation"), dict) else {})
            else:
                raise ValueError("Tuntematon toiminto")
            STATUS_CACHE["time"] = 0
            self.send_json({"ok": True, "result": result})
        except Exception as exc:
            event("error", "POST epäonnistui", error=str(exc))
            self.send_json({"ok": False, "error": str(exc)}, 400)

    def log_message(self, fmt: str, *args: Any) -> None:
        return


def selftest() -> None:
    required = [STATIC / "index.html", STATIC / "app.css", STATIC / "app.js", STATIC / "apps.json", STATIC / "safe.html"]
    missing = [str(x) for x in required if not x.exists()]
    if missing:
        raise SystemExit("Puuttuvat tiedostot: " + ", ".join(missing))
    json.loads((STATIC / "apps.json").read_text(encoding="utf-8"))
    cfg = config()
    assert cfg.get("bme_always_on") is True
    assert cfg.get("ui", {}).get("grid_columns") == 6
    print(json.dumps({"ok": True, "version": VERSION, "files": len(required)}, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(); parser.add_argument("command", nargs="?", default="serve")
    args = parser.parse_args()
    if args.command == "selftest": selftest(); return
    if args.command == "status": print(json.dumps(status(True), ensure_ascii=False, indent=2)); return
    if args.command == "backup": print(make_backup("automatic")); return
    if args.command == "diagnostics": print(diagnostics()); return
    if args.command != "serve": raise SystemExit("Tuntematon komento")
    save_config(config())
    threading.Thread(target=profile_loop, daemon=True).start()
    try: apply_profile(str(config().get("manual_profile", "auto")), force=True)
    except Exception as exc: event("error", "Alkuprofiilin käyttöönotto epäonnistui", error=str(exc))
    event("boot", f"NSPIRE V{VERSION} käynnistyi", port=PORT)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
PY
chmod 755 "$STAGE_ROOT/backend.py"

# -----------------------------------------------------------------------------
# Sovellusmanifestit: kansiot ensin, sovellus vain yhdessä kansiossa.
# -----------------------------------------------------------------------------

cat > "$STAGE_ROOT/static/apps.json" <<'JSON'
[
  {"id":"settings","name":"Asetukset","folder":"Asetukset","icon":"⚙","type":"settings"},
  {"id":"display","name":"Näyttö","folder":"Asetukset","icon":"▣","type":"settings"},
  {"id":"power","name":"Virranhallinta","folder":"Asetukset","icon":"ϟ","type":"settings"},
  {"id":"screensaver","name":"Näytönsäästäjä","folder":"Asetukset","icon":"◐","type":"settings"},

  {"id":"health","name":"Laitteen kunto","folder":"Huolto","icon":"♥","type":"maintenance"},
  {"id":"backup","name":"Varmuuskopiot","folder":"Huolto","icon":"⬡","type":"maintenance"},
  {"id":"diagnostics","name":"Diagnostiikka","folder":"Huolto","icon":"⌁","type":"maintenance"},
  {"id":"recovery","name":"Palautus ja turvatila","folder":"Huolto","icon":"↶","type":"maintenance"},

  {"id":"calculator","name":"Laskin","folder":"Insinöörityökalut","icon":"∑","type":"engineering"},
  {"id":"units","name":"Yksikkömuunnin","folder":"Insinöörityökalut","icon":"⇄","type":"engineering"},
  {"id":"materials","name":"Materiaalit","folder":"Insinöörityökalut","icon":"Fe","type":"engineering"},
  {"id":"threads","name":"Kierteet ja poraus","folder":"Insinöörityökalut","icon":"M","type":"engineering"},
  {"id":"fits","name":"Toleranssit ja sovitteet","folder":"Insinöörityökalut","icon":"±","type":"engineering"},
  {"id":"bearing","name":"Laakerin L10","folder":"Insinöörityökalut","icon":"◎","type":"engineering"},
  {"id":"shaft","name":"Akselin mitoitus","folder":"Insinöörityökalut","icon":"↔","type":"engineering"},
  {"id":"weld","name":"Hitsauslaskuri","folder":"Insinöörityökalut","icon":"△","type":"engineering"},
  {"id":"hydraulic","name":"Hydraulisylinteri","folder":"Insinöörityökalut","icon":"▰","type":"engineering"},
  {"id":"electric","name":"Sähköteho","folder":"Insinöörityökalut","icon":"⚡","type":"engineering"},
  {"id":"statics","name":"Statiikka","folder":"Insinöörityökalut","icon":"ΣF","type":"engineering"},
  {"id":"dynamics","name":"Dynamiikka","folder":"Insinöörityökalut","icon":"a","type":"engineering"},
  {"id":"strength","name":"Lujuusoppi","folder":"Insinöörityökalut","icon":"σ","type":"engineering"},

  {"id":"bme","name":"BME680","folder":"Mittaukset","icon":"°","type":"data"},
  {"id":"weather","name":"Sää","folder":"Mittaukset","icon":"☁","type":"data"},
  {"id":"battery","name":"Akku","folder":"Mittaukset","icon":"▥","type":"data"},

  {"id":"wifi","name":"Wi-Fi","folder":"Verkko","icon":"⌁","type":"settings"},
  {"id":"vnc","name":"VNC","folder":"Verkko","icon":"▤","type":"settings"},
  {"id":"chatgpt","name":"ChatGPT","folder":"Verkko","icon":"AI","type":"web","url":"https://chatgpt.com/"},

  {"id":"calendar","name":"Kalenteri","folder":"Yleiset","icon":"▦","type":"legacy"},
  {"id":"camera","name":"Kamera","folder":"Yleiset","icon":"◉","type":"legacy"},
  {"id":"drawing","name":"Piirto","folder":"Yleiset","icon":"✎","type":"drawing"},
  {"id":"legacy","name":"Nykyiset sovellukset","folder":"Yleiset","icon":"V9","type":"legacy"}
]
JSON

cat > "$STAGE_ROOT/static/index.html" <<'HTML'
<!doctype html>
<html lang="fi">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
  <title>NSPIRE V10</title>
  <link rel="stylesheet" href="/static/app.css">
</head>
<body>
<div id="app">
  <header id="topbar">
    <button id="backBtn" class="top-btn hidden" aria-label="Takaisin">←</button>
    <button id="homeBtn" class="brand">NSPIRE <span>V10</span></button>
    <button id="searchBtn" class="top-btn" aria-label="Haku">⌕</button>
    <button id="loadPill" class="metric">Kuorma --%</button>
    <span id="tempPill" class="metric">--°</span>
    <span id="batteryPill" class="metric">--%</span>
    <button id="quickBtn" class="top-btn" aria-label="Pika-asetukset">☰</button>
    <span id="clock">--:--</span>
  </header>

  <main id="content">
    <section id="homeView" class="view active">
      <div class="home-title"><div><h1>Etusivu</h1><small id="homeInfo">Kansiot aakkosjärjestyksessä</small></div><button id="refreshHome" class="small-btn">↻</button></div>
      <div id="homeGrid" class="app-grid"></div>
    </section>
    <section id="folderView" class="view"><div class="view-head"><h1 id="folderTitle">Kansio</h1></div><div id="folderGrid" class="app-grid"></div></section>
    <section id="appView" class="view"><div id="appContent" class="app-content"></div></section>
  </main>

  <button id="scrollUp" class="scroll-btn up hidden">▲</button>
  <button id="scrollDown" class="scroll-btn down hidden">▼</button>

  <div id="quickPanel" class="overlay hidden">
    <div class="overlay-head"><h2>Pika-asetukset</h2><button data-close="quickPanel">×</button></div>
    <div class="quick-grid">
      <button data-profile="auto">Automaattinen</button><button data-profile="performance">Teho</button>
      <button data-profile="maintenance">Ylläpito</button><button data-profile="saver">Säästö</button>
      <button id="wifiQuick">Wi-Fi</button><button id="vncQuick">VNC</button>
      <button id="saverNow">Näytönsäästäjä nyt</button><button id="screenOff">Näyttö pois</button>
      <button id="restartUi">UI uudelleen</button><button data-open-app="health">Laitteen kunto</button>
    </div>
    <label class="range-row">Kirkkaus <input id="brightnessRange" type="range" min="1" max="100"><output id="brightnessOut">--%</output></label>
  </div>

  <div id="searchPanel" class="overlay hidden">
    <div class="overlay-head"><h2>Sovellushaku</h2><button data-close="searchPanel">×</button></div>
    <input id="searchInput" class="search-input" placeholder="Kirjoita sovelluksen nimi" autocomplete="off">
    <div class="search-tabs"><button data-search-mode="all" class="active">Kaikki</button><button data-search-mode="favorites">Suosikit</button><button data-search-mode="recent">Viimeksi käytetyt</button></div>
    <div id="searchResults" class="search-results"></div>
  </div>

  <div id="toast" class="toast hidden"></div>
  <div id="dimLayer" class="dim-layer hidden"></div>
  <div id="screensaver" class="screensaver hidden" tabindex="0"></div>
</div>
<script src="/static/app.js" defer></script>
</body>
</html>
HTML

cat > "$STAGE_ROOT/static/safe.html" <<'HTML'
<!doctype html><html lang="fi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>NSPIRE V10 turvatila</title><link rel="stylesheet" href="/static/app.css"></head>
<body class="safe-body"><main class="safe-card"><h1>NSPIRE V10 – turvatila</h1><p>Normaalin käyttöliittymän käynnistys keskeytettiin toistuvien virheiden vuoksi.</p><div class="safe-actions"><button onclick="act('safe_mode',{enabled:false})">Käynnistä normaalisti</button><button onclick="act('diagnostics')">Luo diagnostiikka</button><button onclick="act('rollback')">Palauta aiempi järjestelmä</button><button onclick="act('restart_all')">Käynnistä V10 uudelleen</button></div><pre id="out">Haetaan tilaa…</pre></main>
<script>async function api(body){let r=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});return r.json()} async function act(action,x={}){document.querySelector('#out').textContent=JSON.stringify(await api({action,...x}),null,2)} fetch('/api/status').then(r=>r.json()).then(x=>document.querySelector('#out').textContent=JSON.stringify(x,null,2));</script></body></html>
HTML

cat > "$STAGE_ROOT/static/app.css" <<'CSS'
:root{--bg:#05090e;--bg2:#0b1119;--surface:#111a25;--surface2:#172331;--line:#2d4156;--text:#f4f7fa;--muted:#9fb0bf;--accent:#61b9ff;--good:#72d49a;--warn:#ffd166;--bad:#ff7777;--bar-h:40px;--shadow:0 8px 28px #000b}
*{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;overflow:hidden;background:#000;color:var(--text);font-family:system-ui,-apple-system,sans-serif}button,input,select{font:inherit}button{cursor:pointer}.hidden{display:none!important}
#app{height:100%;background:linear-gradient(180deg,var(--bg),var(--bg2));overflow:hidden}#topbar{height:var(--bar-h);display:flex;align-items:center;gap:5px;padding:4px 6px;background:#070c12;border-bottom:1px solid var(--line);position:relative;z-index:40}.brand{height:31px;border:0;background:transparent;color:#fff;font-weight:800;letter-spacing:.5px;padding:0 5px}.brand span{color:var(--accent)}.top-btn,.metric{height:31px;min-width:34px;border:1px solid var(--line);border-radius:9px;background:#111b27;color:var(--text);padding:0 7px}.metric{display:flex;align-items:center;white-space:nowrap;font-size:12px}.metric.warn{color:var(--warn)}.metric.bad{color:var(--bad)}#clock{margin-left:auto;font:700 13px ui-monospace,monospace;min-width:39px;text-align:right}
#content{height:calc(100% - var(--bar-h));overflow:hidden}.view{display:none;height:100%;overflow:auto;padding:7px 34px 8px 7px;scroll-behavior:auto}.view.active{display:block}.home-title,.view-head{display:flex;justify-content:space-between;align-items:center;min-height:38px;margin-bottom:5px}.home-title h1,.view-head h1{font-size:17px;margin:0}.home-title small{color:var(--muted);font-size:10px}.small-btn{border:1px solid var(--line);background:var(--surface);color:#fff;border-radius:8px;min-width:34px;min-height:31px}
.app-grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));grid-auto-rows:72px;gap:5px;align-content:start}.app-tile{position:relative;border:1px solid var(--line);background:linear-gradient(145deg,var(--surface2),var(--surface));color:#fff;border-radius:10px;padding:5px 3px;display:flex;flex-direction:column;align-items:center;justify-content:center;min-width:0;overflow:hidden;box-shadow:0 2px 8px #0005}.app-tile:active{transform:translateY(1px)}.app-icon{font:400 23px/1 ui-monospace,monospace;color:var(--accent);height:27px;display:flex;align-items:center}.app-name{font-size:10px;line-height:1.05;text-align:center;max-width:100%;overflow:hidden;text-overflow:ellipsis}.folder-tile .app-icon{color:var(--warn)}.favorite-mark{position:absolute;right:3px;top:2px;color:var(--warn);font-size:12px}.app-content{min-height:100%}
.scroll-btn{position:fixed;right:5px;z-index:60;width:27px;height:43px;border:1px solid var(--line);border-radius:9px;background:#111b27e8;color:#fff}.scroll-btn.up{top:47px}.scroll-btn.down{bottom:7px}
.overlay{position:fixed;z-index:120;inset:43px 7px 7px;background:#070c12f7;border:1px solid var(--line);border-radius:13px;box-shadow:var(--shadow);overflow:auto;padding:10px}.overlay-head{display:flex;align-items:center;justify-content:space-between;position:sticky;top:-10px;background:#070c12;padding:5px 0;z-index:2}.overlay-head h2{font-size:18px;margin:0}.overlay-head button{width:40px;height:35px;border:1px solid var(--line);background:var(--surface);color:#fff;border-radius:9px;font-size:20px}.quick-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px}.quick-grid button,.action-btn{min-height:44px;border:1px solid var(--line);border-radius:10px;background:var(--surface2);color:#fff;padding:6px}.quick-grid button.active{border-color:var(--accent);box-shadow:inset 0 0 0 1px var(--accent)}.range-row{display:grid;grid-template-columns:auto 1fr 42px;gap:8px;align-items:center;margin-top:12px;background:var(--surface);padding:9px;border-radius:10px}.search-input{width:100%;height:42px;border:1px solid var(--line);border-radius:10px;background:#0c141e;color:#fff;padding:8px 10px;font-size:16px}.search-tabs{display:flex;gap:6px;margin:8px 0}.search-tabs button{border:1px solid var(--line);background:var(--surface);color:#fff;border-radius:8px;padding:7px}.search-tabs button.active{border-color:var(--accent)}.search-results{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:7px}.search-result{min-height:58px;border:1px solid var(--line);background:var(--surface);color:#fff;border-radius:10px;text-align:left;padding:6px}.search-result b{display:block;font-size:12px}.search-result small{color:var(--muted);font-size:10px}
.panel{background:var(--surface);border:1px solid var(--line);border-radius:11px;padding:9px;margin-bottom:8px}.panel h2,.panel h3{margin:0 0 7px;color:var(--accent)}.panel h2{font-size:18px}.panel h3{font-size:14px}.cards{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:7px}.stat-card{background:#0b131c;border:1px solid var(--line);border-radius:9px;padding:7px;min-width:0}.stat-card small{color:var(--muted)}.stat-card b{display:block;font-size:18px;overflow:hidden;text-overflow:ellipsis}.form-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px}.form-grid label{display:grid;gap:3px;color:var(--muted);font-size:11px}.form-grid input,.form-grid select,.input{height:38px;border:1px solid var(--line);border-radius:8px;background:#090f16;color:#fff;padding:5px;min-width:0}.button-row{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}.button-row button{min-height:38px;border:1px solid var(--line);background:var(--surface2);color:#fff;border-radius:9px;padding:6px 9px}.button-row button.danger{border-color:#753f45;color:#ffb4b4}.output{white-space:pre-wrap;background:#030609;border:1px solid #1e2c3b;border-radius:9px;padding:9px;min-height:48px;font:12px/1.4 ui-monospace,monospace;margin-top:8px}.data-table{width:100%;border-collapse:collapse;font-size:11px}.data-table th,.data-table td{border-bottom:1px solid #26394c;padding:5px;text-align:left}.iframe-wrap{height:calc(100vh - 62px);border:1px solid var(--line);border-radius:10px;overflow:hidden}.iframe-wrap iframe{width:100%;height:100%;border:0;background:#fff}.canvas-wrap canvas{width:100%;height:300px;background:#fff;border-radius:9px;touch-action:none}.toast{position:fixed;z-index:300;left:50%;bottom:16px;transform:translateX(-50%);background:#111b27;color:#fff;border:1px solid var(--line);border-radius:10px;padding:8px 12px;box-shadow:var(--shadow);max-width:90%}
.dim-layer{position:fixed;z-index:180;inset:0;background:#0009;pointer-events:none}.screensaver{position:fixed;z-index:200;inset:0;background:#000;color:#fff;display:flex;align-items:center;justify-content:center}.saver-sofa{width:100%;height:100%;display:grid;grid-template-rows:1fr auto;align-items:center;padding:20px;font-weight:400}.saver-clock{font:400 min(24vw,120px)/1 ui-monospace,monospace;text-align:center;letter-spacing:-5px}.saver-metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;width:100%;font-weight:400}.saver-metric{border-top:1px solid #333;padding:9px;text-align:center}.saver-metric b{font-size:24px;font-weight:400;display:block}.sleep-color{position:absolute;inset:0}.saver-info{position:relative;z-index:2;text-align:center;font-weight:400}.safe-body{display:grid;place-items:center;background:#000;overflow:auto}.safe-card{width:min(620px,94vw);background:#111a25;border:1px solid var(--line);border-radius:14px;padding:16px}.safe-actions{display:grid;grid-template-columns:repeat(2,1fr);gap:8px}.safe-actions button{min-height:48px;border:1px solid var(--line);background:#172331;color:#fff;border-radius:10px}.safe-card pre{white-space:pre-wrap;max-height:220px;overflow:auto;background:#030609;padding:8px;border-radius:8px}
@media(max-width:520px){.app-grid{grid-template-columns:repeat(5,minmax(0,1fr));grid-auto-rows:70px}.search-results{grid-template-columns:repeat(2,minmax(0,1fr))}.cards{grid-template-columns:repeat(2,minmax(0,1fr))}}
CSS

cat > "$STAGE_ROOT/static/app.js" <<'JS'
(()=>{'use strict';
const API='/api';
const S={apps:[],folders:[],status:null,config:null,stack:[],currentFolder:null,currentApp:null,searchMode:'all',favorites:new Set(JSON.parse(localStorage.getItem('n10-favorites')||'[]')),recent:JSON.parse(localStorage.getItem('n10-recent')||'[]').slice(0,12),idleTimer:null,dimTimer:null,saverVisible:false,lastStatusAt:0};
const $=(q,r=document)=>r.querySelector(q), $$=(q,r=document)=>[...r.querySelectorAll(q)];
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function get(path){const r=await fetch(API+path,{cache:'no-store'});if(!r.ok)throw Error('HTTP '+r.status);return r.json()}
async function action(body){const r=await fetch(API+'/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const x=await r.json();if(!r.ok||x.ok===false)throw Error(x.error||'Toiminto epäonnistui');return x.result}
function toast(msg){const t=$('#toast');t.textContent=msg;t.classList.remove('hidden');clearTimeout(t._timer);t._timer=setTimeout(()=>t.classList.add('hidden'),2600)}
function setView(id){$$('.view').forEach(v=>v.classList.toggle('active',v.id===id));$('#backBtn').classList.toggle('hidden',id==='homeView');requestAnimationFrame(updateScrollButtons)}
function pushState(kind,value){S.stack.push({kind,value});history.replaceState({nspire:true},'')}
function home(){S.stack=[];S.currentFolder=null;S.currentApp=null;setView('homeView');renderHome()}
function back(){if($('#quickPanel:not(.hidden)')){closeOverlay('quickPanel');return}if($('#searchPanel:not(.hidden)')){closeOverlay('searchPanel');return}if(S.stack.length<=1){home();return}S.stack.pop();const prev=S.stack[S.stack.length-1];if(prev.kind==='folder')openFolder(prev.value,false);else home()}
function tile(icon,name,cls=''){return `<span class="app-icon">${esc(icon)}</span><span class="app-name">${esc(name)}</span>`}
function renderHome(){const grid=$('#homeGrid');grid.innerHTML='';S.folders.forEach(name=>{const b=document.createElement('button');b.className='app-tile folder-tile';b.innerHTML=tile('▣',name);b.onclick=()=>openFolder(name);grid.appendChild(b)});$('#homeInfo').textContent=`${S.folders.length} kansiota · ${S.apps.length} sovellusta`;requestAnimationFrame(updateScrollButtons)}
function openFolder(name,push=true){S.currentFolder=name;S.currentApp=null;if(push)pushState('folder',name);$('#folderTitle').textContent=name;const apps=S.apps.filter(a=>a.folder===name).sort((a,b)=>a.name.localeCompare(b.name,'fi'));const grid=$('#folderGrid');grid.innerHTML='';apps.forEach(app=>grid.appendChild(appTile(app)));setView('folderView')}
function appTile(app){const b=document.createElement('button');b.className='app-tile';b.dataset.app=app.id;b.innerHTML=tile(app.icon||'•',app.name)+(S.favorites.has(app.id)?'<span class="favorite-mark">★</span>':'');b.onclick=()=>openApp(app);b.oncontextmenu=e=>{e.preventDefault();toggleFavorite(app.id);if(S.currentFolder)openFolder(S.currentFolder,false)};return b}
function toggleFavorite(id){if(S.favorites.has(id))S.favorites.delete(id);else S.favorites.add(id);localStorage.setItem('n10-favorites',JSON.stringify([...S.favorites]));renderSearch()}
function markRecent(id){S.recent=[id,...S.recent.filter(x=>x!==id)].slice(0,12);localStorage.setItem('n10-recent',JSON.stringify(S.recent))}
function openApp(app,push=true){S.currentApp=app;markRecent(app.id);if(push)pushState('app',app.id);setView('appView');renderApp(app);action({action:'event',kind:'app',message:'Avattiin '+app.name}).catch(()=>{})}
function appById(id){return S.apps.find(a=>a.id===id)}
function openAppById(id){const a=appById(id);if(a){closeAllOverlays();openApp(a)}}
function closeOverlay(id){$('#'+id)?.classList.add('hidden')}
function closeAllOverlays(){closeOverlay('quickPanel');closeOverlay('searchPanel')}
function updateScrollButtons(){const v=$('.view.active');if(!v)return;const can=v.scrollHeight>v.clientHeight+4;$('#scrollUp').classList.toggle('hidden',!can);$('#scrollDown').classList.toggle('hidden',!can);if(can){$('#scrollUp').disabled=v.scrollTop<3;$('#scrollDown').disabled=v.scrollTop+v.clientHeight>=v.scrollHeight-3}}
function fmt(v,s=''){return v===null||v===undefined||Number.isNaN(v)?'--':`${v}${s}`}
function updateTop(s){const load=$('#loadPill');load.textContent=`Kuorma ${fmt(s.cpu_percent,'%')}`;load.className='metric'+(s.cpu_percent>85?' bad':s.cpu_percent>60?' warn':'');$('#tempPill').textContent=fmt(s.temperature_c,'°');const b=s.battery||{};$('#batteryPill').textContent=(b.charging?'⚡':'')+fmt(b.percent,'%');$('#brightnessRange').value=s.brightness??50;$('#brightnessOut').value=fmt(s.brightness,'%');$$('[data-profile]').forEach(x=>x.classList.toggle('active',x.dataset.profile===(s.requested_profile||s.profile)))}
async function refreshStatus(force=false){if(document.hidden&&!force)return;try{const s=await get('/status');S.status=s;S.config=s.config;updateTop(s);if(S.currentApp&&['health','battery','settings','display','power','screensaver','wifi','vnc'].includes(S.currentApp.id))renderApp(S.currentApp,true)}catch(e){$('#loadPill').textContent='Kuorma ?';}}
function clock(){const d=new Date();$('#clock').textContent=d.toLocaleTimeString('fi-FI',{hour:'2-digit',minute:'2-digit'});if(S.saverVisible){const c=$('.saver-clock');if(c)c.textContent=d.toLocaleTimeString('fi-FI',{hour:'2-digit',minute:'2-digit'})}}
function openQuick(){closeOverlay('searchPanel');$('#quickPanel').classList.remove('hidden')}
function openSearch(){closeOverlay('quickPanel');$('#searchPanel').classList.remove('hidden');$('#searchInput').focus();renderSearch()}
function renderSearch(){const q=$('#searchInput').value.trim().toLocaleLowerCase('fi');let apps=S.apps;if(S.searchMode==='favorites')apps=apps.filter(a=>S.favorites.has(a.id));if(S.searchMode==='recent')apps=S.recent.map(appById).filter(Boolean);if(q)apps=apps.filter(a=>(a.name+' '+a.folder).toLocaleLowerCase('fi').includes(q));const out=$('#searchResults');out.innerHTML='';apps.slice(0,50).forEach(a=>{const b=document.createElement('button');b.className='search-result';b.innerHTML=`<span>${S.favorites.has(a.id)?'★ ':''}${esc(a.icon||'')}</span><b>${esc(a.name)}</b><small>${esc(a.folder)}</small>`;b.onclick=()=>openAppById(a.id);b.oncontextmenu=e=>{e.preventDefault();toggleFavorite(a.id)};out.appendChild(b)})}
function panel(title,body){return `<section class="panel"><h2>${esc(title)}</h2>${body}</section>`}
function cards(rows){return `<div class="cards">${rows.map(([a,b])=>`<div class="stat-card"><small>${esc(a)}</small><b>${esc(b)}</b></div>`).join('')}</div>`}
function formField(label,id,value='',type='number',step='any'){return `<label>${esc(label)}<input id="${id}" type="${type}" step="${step}" value="${esc(value)}"></label>`}
function output(id='toolOut'){return `<pre id="${id}" class="output">Syötä arvot ja laske.</pre>`}
function settingsHtml(kind){const s=S.status||{},c=s.config||S.config||{},p=c.profiles||{},ss=c.screensaver||{};if(kind==='display')return panel('Näyttö',`<label class="range-row">Kirkkaus <input id="displayBrightness" type="range" min="1" max="100" value="${s.brightness??60}"><output>${fmt(s.brightness,'%')}</output></label><div class="button-row"><button data-bright="25">25 %</button><button data-bright="50">50 %</button><button data-bright="75">75 %</button><button data-bright="100">100 %</button><button data-action="screenOff">Näyttö pois</button></div>`);
if(kind==='screensaver')return panel('Näytönsäästäjä',`<div class="form-grid"><label>Profiili<select id="ssProfile"><option value="sofa2">Sohva 2</option><option value="black">Musta näyttö</option><option value="sleep">Unikello</option><option value="info">Tietonäkymä</option></select></label>${formField('Viive sekunteina','ssDelay',ss.delay_seconds||120,'number','1')}${formField('Himmennys ennen (s)','ssDim',ss.dim_seconds_before||15,'number','1')}</div><div class="button-row"><button data-action="saveScreensaver">Tallenna</button><button data-action="saverNow">Testaa nyt</button></div><div class="output">Yksi tapahtumapohjainen ajastin. Kosketus tai näppäin nollaa ajastimen. Epäonnistuessa ei käynnisty uutta yrityssilmukkaa.</div>`);
if(kind==='power')return powerHtml();
if(kind==='wifi'||kind==='vnc')return panel('Verkko',cards([['Wi-Fi',s.wifi?.connected?s.wifi.ssid||'Yhdistetty':'Ei yhteyttä'],['VNC','Ohjataan palveluina'],['Profiili',s.profile||'--']])+`<div class="button-row"><button data-net="wifi-on">Wi-Fi päälle</button><button data-net="wifi-off">Wi-Fi pois</button><button data-net="vnc-on">VNC päälle</button><button data-net="vnc-off">VNC pois</button></div>`);
return panel('Asetukset',cards([['Versio',s.version||'10.0.0'],['Profiili',s.profile||'--'],['Ruudukko','6 × 5'],['BME680','Aina käytössä'],['Päivitys',fmt(c.ui?.status_seconds||4,' s')],['Animaatiot',c.ui?.animations?'Päällä':'Pois']])+`<div class="button-row"><button data-open="display">Näyttö</button><button data-open="power">Virta</button><button data-open="screensaver">Näytönsäästäjä</button><button data-open="wifi">Verkko</button></div>`)}
function powerHtml(){const s=S.status||{},c=s.config||{},profiles=c.profiles||{};let html=panel('Virtatila',`<div class="button-row"><button data-prof="auto">Automaattinen</button><button data-prof="performance">Teho</button><button data-prof="maintenance">Ylläpito</button><button data-prof="saver">Säästö</button></div><div class="output">Automaattinen: latauksessa Teho, akulla Ylläpito. Säästö valitaan käsin. BME680 säilyy käytössä kaikissa tiloissa.</div>`);for(const name of ['performance','maintenance','saver']){const p=profiles[name]||{};html+=`<section class="panel profile-editor" data-profile-editor="${name}"><h3>${esc(p.label||name)}</h3><div class="form-grid">${formField('CPU maksimi %','cpu_'+name,p.max_cpu_percent||75)}${formField('Kirkkaus %','br_'+name,p.brightness||60)}${formField('Tilapäivitys s','poll_'+name,p.status_seconds||7)}${formField('Näytönsäästäjä s','timeout_'+name,p.screensaver_seconds||120)}</div><div class="button-row"><button data-save-profile="${name}">Tallenna profiili</button></div></section>`}return html}
function healthHtml(){const s=S.status||{};return panel('Laitteen kunto',cards([['CPU',fmt(s.cpu_percent,'%')],['Lämpö',fmt(s.temperature_c,' °C')],['Taajuus',fmt(s.frequency_mhz,' MHz')],['RAM',fmt(s.ram_percent,'%')],['Swap',fmt(s.swap_percent,'%')],['Käynnissä',fmt(Math.floor((s.uptime_seconds||0)/60),' min')],['Akku',fmt(s.battery?.percent,'%')],['Profiili',s.profile||'--'],['Turvatila',s.safe_mode?'Päällä':'Pois']])+`<h3>Palvelut</h3><table class="data-table">${(s.services||[]).map(x=>`<tr><td>${esc(x.name)}</td><td>${x.active?'Käynnissä':'Pois'}</td></tr>`).join('')}</table><h3>Raskaimmat prosessit</h3><table class="data-table"><tr><th>Prosessi</th><th>CPU</th><th>RAM</th></tr>${(s.top_processes||[]).map(x=>`<tr><td>${esc(x.name)}</td><td>${x.cpu}%</td><td>${x.memory}%</td></tr>`).join('')}</table>`)}
function maintenanceHtml(id){if(id==='health')return healthHtml();const events=(S.status?.events||[]).slice().reverse();if(id==='backup')return panel('Varmuuskopiot',`<p>V10:n asetukset, käyttöliittymä, tila ja palvelut tallennetaan yhteen arkistoon.</p><div class="button-row"><button data-maint="backup">Luo varmuuskopio</button></div>${output('maintOut')}`);if(id==='diagnostics')return panel('Diagnostiikka',`<p>Luo raportin /home/mavks-kansioon.</p><div class="button-row"><button data-maint="diagnostics">Luo raportti</button><button data-maint="restart_ui">Käynnistä UI uudelleen</button><button data-maint="restart_all">Käynnistä V10 uudelleen</button></div><h3>Tapahtumat</h3><table class="data-table">${events.map(e=>`<tr><td>${new Date(e.time*1000).toLocaleTimeString('fi-FI')}</td><td>${esc(e.kind)}</td><td>${esc(e.message)}</td></tr>`).join('')}</table>${output('maintOut')}`);return panel('Palautus ja turvatila',`<p>Turvatila käynnistyy automaattisesti, jos V10 epäonnistuu toistuvasti. Palautus ottaa käyttöön aiemman kioskijärjestelmän.</p><div class="button-row"><button data-maint="safe_on">Käynnistä turvatilaan</button><button data-maint="safe_off">Poistu turvatilasta</button><button class="danger" data-maint="rollback">Palauta aiempi järjestelmä</button></div>${output('maintOut')}`)}
function findDeep(obj,names){if(!obj||typeof obj!=='object')return undefined;for(const n of names)if(obj[n]!==undefined&&obj[n]!==null)return obj[n];for(const v of Object.values(obj)){const x=findDeep(v,names);if(x!==undefined)return x}}
async function dataHtml(id){if(id==='battery')return panel('Akku',cards([['Varaus',fmt(S.status?.battery?.percent,'%')],['Lataus',S.status?.battery?.charging?'Kyllä':'Ei'],['Tila',S.status?.battery?.status||'--'],['Lähde',S.status?.battery?.source||'--']]));const path=id==='weather'?'/weather':'/sensors';let x;try{x=await get(path)}catch(e){x={ok:false,error:e.message}}const d=x.data||{};if(id==='weather')return panel('Sää',cards([['Lämpö',fmt(findDeep(d,['temperature','temp','temperature_c','outside_temperature']),' °C')],['Kosteus',fmt(findDeep(d,['humidity','humidity_percent']),' %')],['Ennuste',findDeep(d,['description','summary','condition'])||'Legacy-sääpalvelusta']])+`<details><summary>Raakadata</summary><pre class="output">${esc(JSON.stringify(x,null,2))}</pre></details>`);return panel('BME680',cards([['Lämpö',fmt(findDeep(d,['temperature','temp','temperature_c','inside_temperature']),' °C')],['Kosteus',fmt(findDeep(d,['humidity','humidity_percent']),' %')],['Paine',fmt(findDeep(d,['pressure','pressure_hpa']),' hPa')],['IAQ',fmt(findDeep(d,['iaq','air_quality']))],['Kaasu',fmt(findDeep(d,['gas','gas_resistance']))],['Lähde',x.ok?`Portti ${x.port}`:'Ei vastausta']])+`<div class="output">BME680-palvelua ei sammuteta missään virtaprofiilissa.</div><details><summary>Raakadata</summary><pre class="output">${esc(JSON.stringify(x,null,2))}</pre></details>`)}
const materials=[['S235','Teräs',210000,235,7850],['S355','Teräs',210000,355,7850],['42CrMo4','Nuorrutusteräs',210000,650,7850],['Al 6082-T6','Alumiini',70000,250,2700],['AISI 304','Ruostumaton',193000,215,8000],['POM','Muovi',3000,65,1410]];
const threads=[['M2',0.40,1.6],['M2.5',0.45,2.05],['M3',0.50,2.5],['M4',0.70,3.3],['M5',0.80,4.2],['M6',1.00,5.0],['M8',1.25,6.8],['M10',1.50,8.5],['M12',1.75,10.2],['M16',2.00,14.0],['M20',2.50,17.5]];
function engineeringHtml(id){if(id==='materials')return panel('Materiaalit',`<table class="data-table"><tr><th>Materiaali</th><th>Ryhmä</th><th>E MPa</th><th>Re MPa</th><th>ρ kg/m³</th></tr>${materials.map(r=>`<tr>${r.map(x=>`<td>${x}</td>`).join('')}</tr>`).join('')}</table>`);if(id==='threads')return panel('Kierteet ja poraus',`<table class="data-table"><tr><th>Kierre</th><th>Nousu mm</th><th>Poraus mm</th></tr>${threads.map(r=>`<tr>${r.map(x=>`<td>${x}</td>`).join('')}</tr>`).join('')}</table>`);if(id==='fits')return panel('Toleranssit ja sovitteet',`<table class="data-table"><tr><th>Sovite</th><th>Luonne</th><th>Käyttö</th></tr><tr><td>H7/g6</td><td>Välyssovite</td><td>Tarkka liuku</td></tr><tr><td>H7/h6</td><td>Pieni välys</td><td>Ohjaus</td></tr><tr><td>H7/k6</td><td>Välisovite</td><td>Kevyt puristus</td></tr><tr><td>H7/p6</td><td>Puristussovite</td><td>Pysyvä liitos</td></tr></table><div class="output">Tarkat ISO 286 -poikkeamat riippuvat nimellismitasta. Tämä näkymä toimii sovitetyypin pikaoppaana.</div>`);if(id==='calculator')return panel('Laskin',`<div class="form-grid">${formField('Luku A','ca',0)}${formField('Luku B','cb',0)}<label>Toiminto<select id="cop"><option value="add">A + B</option><option value="sub">A − B</option><option value="mul">A × B</option><option value="div">A ÷ B</option><option value="pow">A^B</option><option value="sqrt">√A</option></select></label></div><div class="button-row"><button data-calc="calculator">Laske</button></div>${output()}`);if(id==='units')return panel('Yksikkömuunnin',`<div class="form-grid">${formField('Arvo','uval',1)}<label>Suure<select id="ucat"><option value="length">Pituus</option><option value="pressure">Paine</option><option value="torque">Momentti</option><option value="power">Teho</option><option value="energy">Energia</option><option value="temperature">Lämpötila</option></select></label><label>Lähtöyksikkö<select id="ufrom"></select></label><label>Kohdeyksikkö<select id="uto"></select></label></div><div class="button-row"><button data-calc="units">Muunna</button></div>${output()}`);const forms={bearing:[['Dynaaminen kantavuus C (N)','C',10000],['Ekvivalenttikuorma P (N)','P',2000],['Pyörimisnopeus n (rpm)','n',1000],['Eksponentti p (3 kuula, 3.333 rulla)','p',3]],shaft:[['Momentti T (Nm)','T',100],['Sallittu leikkausjännitys τ (MPa)','tau',50]],weld:[['Voima F (N)','F',10000],['Hitsin kokonaispituus L (mm)','L',100],['Sallittu leikkausjännitys τ (MPa)','tau',80]],hydraulic:[['Paine p (bar)','pbar',100],['Männän halkaisija d (mm)','d',50],['Varren halkaisija d₂ (mm)','d2',25]],electric:[['Jännite U (V)','U',230],['Virta I (A)','I',10],['Tehokerroin cos φ','cos',1]],statics:[['Palkin pituus L (m)','L',4],['Pistekuorma F (N)','F',1000],['Kuorman etäisyys vasemmalta a (m)','a',2]],dynamics:[['Alkunopeus v₀ (m/s)','v0',0],['Kiihtyvyys a (m/s²)','a',2],['Aika t (s)','t',5]],strength:[['Voima F (N)','F',10000],['Poikkipinta-ala A (mm²)','A',100],['Pituus L (mm)','L',1000],['Kimmomoduuli E (MPa)','E',210000]]};const title=appById(id)?.name||id;return panel(title,`<div class="form-grid">${(forms[id]||[]).map(x=>formField(x[0],x[1],x[2])).join('')}</div><div class="button-row"><button data-calc="${id}">Laske</button><button data-save-result>Tallenna tulos</button></div>${output()}`)}
function drawingHtml(){return panel('Piirto',`<div class="canvas-wrap"><canvas id="drawCanvas" width="600" height="300"></canvas></div><div class="button-row"><button data-draw="clear">Tyhjennä</button><button data-draw="black">Musta</button><button data-draw="red">Punainen</button><button data-draw="blue">Sininen</button></div>`)}
async function renderApp(app,refresh=false){const root=$('#appContent');if(!refresh)root.innerHTML='<section class="panel"><h2>Ladataan…</h2></section>';let html='';if(app.type==='settings')html=settingsHtml(app.id);else if(app.type==='maintenance')html=maintenanceHtml(app.id);else if(app.type==='engineering')html=engineeringHtml(app.id);else if(app.type==='data')html=await dataHtml(app.id);else if(app.type==='drawing')html=drawingHtml();else if(app.type==='web')html=panel(app.name,`<div class="iframe-wrap"><iframe src="${esc(app.url)}"></iframe></div>`);else if(app.type==='legacy')html=panel(app.name,`<div class="iframe-wrap"><iframe src="http://127.0.0.1:8765/"></iframe></div>`);root.innerHTML=`<div class="view-head"><h1>${esc(app.name)}</h1><button class="small-btn" data-favorite>${S.favorites.has(app.id)?'★':'☆'}</button></div>${html}`;bindAppActions(app);requestAnimationFrame(updateScrollButtons)}
function num(id){return Number($('#'+id)?.value||0)}
const units={length:{mm:1,m:1000,cm:10,in:25.4,ft:304.8},pressure:{Pa:1,kPa:1000,MPa:1e6,bar:1e5,psi:6894.757},torque:{Nm:1,Nmm:.001,kNm:1000,lbft:1.3558179},power:{W:1,kW:1000,hp:745.6999},energy:{J:1,kJ:1000,Wh:3600,kWh:3.6e6},temperature:{C:1,F:1,K:1}};
function updateUnitOptions(){const cat=$('#ucat')?.value||'length',keys=Object.keys(units[cat]);for(const id of ['ufrom','uto']){const el=$('#'+id);if(el)el.innerHTML=keys.map(x=>`<option>${x}</option>`).join('')}if($('#uto'))$('#uto').selectedIndex=Math.min(1,keys.length-1)}
function calc(id){let text='';if(id==='calculator'){const a=num('ca'),b=num('cb'),op=$('#cop').value;const r={add:a+b,sub:a-b,mul:a*b,div:b?a/b:NaN,pow:a**b,sqrt:Math.sqrt(a)}[op];text=`Lähtötiedot:\nA = ${a}\nB = ${b}\n\nTulos:\n${Number.isFinite(r)?r.toFixed(3):'Ei määritelty'}`}
else if(id==='units'){const cat=$('#ucat').value,from=$('#ufrom').value,to=$('#uto').value,v=num('uval');let r;if(cat==='temperature'){const c=from==='C'?v:from==='F'?(v-32)*5/9:v-273.15;r=to==='C'?c:to==='F'?c*9/5+32:c+273.15}else r=v*units[cat][from]/units[cat][to];text=`Lähtötieto:\n${v} ${from}\n\nMuunnos:\n${r.toFixed(6)} ${to}`}
else if(id==='bearing'){const C=num('C'),P=num('P'),n=num('n'),p=num('p');const L10=(C/P)**p*1e6, h=L10/(60*n);text=`Kaava:\nL₁₀ = (C/P)^p · 10⁶\n\nVälitulokset:\nL₁₀ = ${L10.toFixed(0)} kierrosta\n\nLopputulos:\nL₁₀h = ${h.toFixed(3)} h`}
else if(id==='shaft'){const T=num('T')*1000,t=num('tau'),d=(16*T/(Math.PI*t))**(1/3);text=`Kaava:\nd = ∛(16T / (π·τ_sall))\n\nLopputulos:\nd = ${d.toFixed(3)} mm`}
else if(id==='weld'){const F=num('F'),L=num('L'),t=num('tau'),a=F/(L*t);text=`Kaava:\na = F / (L·τ_sall)\n\nLopputulos:\na = ${a.toFixed(3)} mm`}
else if(id==='hydraulic'){const p=num('pbar')*.1,d=num('d'),d2=num('d2'),A=Math.PI*d*d/4,A2=Math.PI*(d*d-d2*d2)/4;const push=p*A,pull=p*A2;text=`Geometria:\nA = ${A.toFixed(3)} mm²\nA_rengas = ${A2.toFixed(3)} mm²\n\nVoimat:\nTyöntö = ${(push/1000).toFixed(3)} kN\nVeto = ${(pull/1000).toFixed(3)} kN`}
else if(id==='electric'){const U=num('U'),I=num('I'),c=num('cos');text=`Yksivaihe:\nP = U·I·cosφ = ${(U*I*c/1000).toFixed(3)} kW\n\nKolmivaihe:\nP = √3·U·I·cosφ = ${(Math.sqrt(3)*U*I*c/1000).toFixed(3)} kW`}
else if(id==='statics'){const L=num('L'),F=num('F'),a=num('a'),RB=F*a/L,RA=F-RB;text=`Tasapaino:\nΣF_y = 0\nΣM_A = 0\n\nTukireaktiot:\nR_A = ${RA.toFixed(3)} N\nR_B = ${RB.toFixed(3)} N`}
else if(id==='dynamics'){const v0=num('v0'),a=num('a'),t=num('t'),v=v0+a*t,s=v0*t+.5*a*t*t;text=`Nopeus:\nv = v₀ + at = ${v.toFixed(3)} m/s\n\nMatka:\ns = v₀t + ½at² = ${s.toFixed(3)} m`}
else if(id==='strength'){const F=num('F'),A=num('A'),L=num('L'),E=num('E'),sig=F/A,eps=sig/E,dl=eps*L;text=`Jännitys:\nσ = F/A = ${sig.toFixed(3)} MPa\n\nVenymä:\nε = σ/E = ${eps.toExponential(3)}\n\nPitenemä:\nΔL = εL = ${dl.toFixed(3)} mm`}
const out=$('#toolOut');if(out){out.textContent=text;out.dataset.result=text}}
function bindDrawing(){const c=$('#drawCanvas');if(!c)return;const ctx=c.getContext('2d');ctx.lineWidth=3;ctx.lineCap='round';let down=false,last=null;function point(e){const r=c.getBoundingClientRect(),t=e.touches?.[0]||e;return{x:(t.clientX-r.left)*c.width/r.width,y:(t.clientY-r.top)*c.height/r.height}}function start(e){e.preventDefault();down=true;last=point(e)}function move(e){if(!down)return;e.preventDefault();const p=point(e);ctx.beginPath();ctx.moveTo(last.x,last.y);ctx.lineTo(p.x,p.y);ctx.stroke();last=p}function end(){down=false}c.addEventListener('pointerdown',start);c.addEventListener('pointermove',move);addEventListener('pointerup',end)}
function bindAppActions(app){$('[data-favorite]')?.addEventListener('click',()=>{toggleFavorite(app.id);renderApp(app)});$$('[data-open]').forEach(b=>b.onclick=()=>openAppById(b.dataset.open));$$('[data-prof]').forEach(b=>b.onclick=async()=>{await action({action:'profile',profile:b.dataset.prof});toast('Virtaprofiili vaihdettu');await refreshStatus(true)});$$('[data-bright]').forEach(b=>b.onclick=async()=>{await action({action:'brightness',value:Number(b.dataset.bright)});refreshStatus(true)});$('#displayBrightness')?.addEventListener('change',e=>action({action:'brightness',value:Number(e.target.value)}).then(()=>refreshStatus(true)));$$('[data-net]').forEach(b=>b.onclick=async()=>{const [kind,on]=b.dataset.net.split('-');await action({action:kind,enabled:on==='on'});toast('Verkkoasetus päivitetty');refreshStatus(true)});$$('[data-save-profile]').forEach(b=>b.onclick=async()=>{const n=b.dataset.saveProfile,patch={profiles:{[n]:{max_cpu_percent:num('cpu_'+n),brightness:num('br_'+n),status_seconds:num('poll_'+n),screensaver_seconds:num('timeout_'+n)}}};await action({action:'config',patch});toast('Profiili tallennettu');refreshStatus(true)});$$('[data-maint]').forEach(b=>b.onclick=async()=>{const m=b.dataset.maint,out=$('#maintOut');try{let r;if(m==='safe_on')r=await action({action:'safe_mode',enabled:true});else if(m==='safe_off')r=await action({action:'safe_mode',enabled:false});else r=await action({action:m});if(out)out.textContent=JSON.stringify(r,null,2);toast('Toiminto käynnistetty')}catch(e){if(out)out.textContent=e.message}});$$('[data-calc]').forEach(b=>b.onclick=()=>calc(b.dataset.calc));$('[data-save-result]')?.addEventListener('click',async()=>{const text=$('#toolOut')?.dataset.result||$('#toolOut')?.textContent||'';await action({action:'save_calculation',calculation:{tool:app.id,title:app.name,result:text}});toast('Lasku tallennettu')});$('#ucat')?.addEventListener('change',updateUnitOptions);if(app.id==='units')updateUnitOptions();$$('[data-action]').forEach(b=>b.onclick=async()=>{if(b.dataset.action==='screenOff')await action({action:'brightness',value:1});if(b.dataset.action==='saverNow')showSaver('testi');if(b.dataset.action==='saveScreensaver'){await action({action:'config',patch:{screensaver:{profile:$('#ssProfile').value,delay_seconds:num('ssDelay'),dim_seconds_before:num('ssDim')}}});toast('Näytönsäästäjä tallennettu');refreshStatus(true)}});if(app.id==='screensaver'&&$('#ssProfile'))$('#ssProfile').value=S.config?.screensaver?.profile||'sofa2';if(app.id==='drawing'){bindDrawing();$$('[data-draw]').forEach(b=>b.onclick=()=>{const c=$('#drawCanvas'),ctx=c.getContext('2d');if(b.dataset.draw==='clear')ctx.clearRect(0,0,c.width,c.height);else ctx.strokeStyle=b.dataset.draw})}}
function saverHtml(profile){const s=S.status||{},d=new Date(),time=d.toLocaleTimeString('fi-FI',{hour:'2-digit',minute:'2-digit'});if(profile==='black')return '<div style="background:#000;position:absolute;inset:0"></div>';if(profile==='sleep'){const ss=S.config?.screensaver||{},now=time,red=ss.sleep_red_from||'20:00',yellow=ss.sleep_yellow_from||'19:30',green=ss.sleep_green_from||'07:00';let color='#d82020';if(now>=green&&now<yellow)color='#12a84c';else if(now>=yellow&&now<red)color='#e8c31a';return `<div class="sleep-color" style="background:${color}"></div><div class="saver-info"><div class="saver-clock">${time}</div></div>`}if(profile==='info')return `<div class="saver-info"><div class="saver-clock">${time}</div>${cards([['Kuorma',fmt(s.cpu_percent,'%')],['CPU',fmt(s.temperature_c,' °C')],['Akku',fmt(s.battery?.percent,'%')],['Profiili',s.profile||'--']])}</div>`;return `<div class="saver-sofa"><div class="saver-clock">${time}</div><div class="saver-metrics"><div class="saver-metric">Kuorma<b>${fmt(s.cpu_percent,'%')}</b></div><div class="saver-metric">CPU<b>${fmt(s.temperature_c,'°')}</b></div><div class="saver-metric">Akku<b>${fmt(s.battery?.percent,'%')}</b></div><div class="saver-metric">Profiili<b>${esc(s.profile||'--')}</b></div></div></div>`}
function showSaver(reason='ajastin'){if(!S.config?.screensaver?.enabled||S.saverVisible)return;S.saverVisible=true;$('#dimLayer').classList.add('hidden');const el=$('#screensaver');el.innerHTML=saverHtml(S.config?.screensaver?.profile||'sofa2');el.classList.remove('hidden');action({action:'event',kind:'screensaver',message:'Näytönsäästäjä käynnistyi',detail:reason}).catch(()=>{})}
function hideSaver(){if(!S.saverVisible)return;S.saverVisible=false;$('#screensaver').classList.add('hidden');$('#screensaver').innerHTML='';action({action:'event',kind:'screensaver',message:'Näytönsäästäjä suljettiin'}).catch(()=>{})}
function resetIdle(){clearTimeout(S.idleTimer);clearTimeout(S.dimTimer);hideSaver();$('#dimLayer').classList.add('hidden');const ss=S.config?.screensaver||{};if(!ss.enabled)return;const delay=Math.max(20,Number(ss.delay_seconds)||120)*1000,dim=Math.max(0,Number(ss.dim_seconds_before)||0)*1000;if(dim&&delay>dim)S.dimTimer=setTimeout(()=>$('#dimLayer').classList.remove('hidden'),delay-dim);S.idleTimer=setTimeout(()=>showSaver('toimettomuus'),delay)}
async function init(){[S.apps,S.config]=await Promise.all([fetch('/static/apps.json').then(r=>r.json()),get('/config')]);S.apps.sort((a,b)=>a.name.localeCompare(b.name,'fi'));S.folders=[...new Set(S.apps.map(a=>a.folder))].sort((a,b)=>a.localeCompare(b,'fi'));home();pushState('home',null);await refreshStatus(true);resetIdle();setInterval(clock,1000);setInterval(()=>refreshStatus(),4000);clock()}
$('#homeBtn').onclick=home;$('#backBtn').onclick=back;$('#refreshHome').onclick=renderHome;$('#quickBtn').onclick=openQuick;$('#searchBtn').onclick=openSearch;$('#loadPill').onclick=()=>openAppById('health');$('#scrollUp').onclick=()=>$('.view.active')?.scrollBy({top:-220});$('#scrollDown').onclick=()=>$('.view.active')?.scrollBy({top:220});$$('[data-close]').forEach(b=>b.onclick=()=>closeOverlay(b.dataset.close));$('#searchInput').oninput=renderSearch;$$('[data-search-mode]').forEach(b=>b.onclick=()=>{S.searchMode=b.dataset.searchMode;$$('[data-search-mode]').forEach(x=>x.classList.toggle('active',x===b));renderSearch()});$$('[data-profile]').forEach(b=>b.onclick=async()=>{await action({action:'profile',profile:b.dataset.profile});toast('Virtaprofiili vaihdettu');closeOverlay('quickPanel');refreshStatus(true)});$('#brightnessRange').onchange=async e=>{await action({action:'brightness',value:Number(e.target.value)});refreshStatus(true)};$('#wifiQuick').onclick=async()=>{await action({action:'wifi',enabled:!S.status?.wifi?.connected});refreshStatus(true)};$('#vncQuick').onclick=()=>action({action:'vnc',enabled:true}).then(()=>toast('VNC käynnistetty'));$('#saverNow').onclick=()=>{closeOverlay('quickPanel');showSaver('pika-asetus')};$('#screenOff').onclick=()=>action({action:'brightness',value:1});$('#restartUi').onclick=()=>action({action:'restart_ui'});$$('[data-open-app]').forEach(b=>b.onclick=()=>openAppById(b.dataset.openApp));document.addEventListener('scroll',updateScrollButtons,true);for(const ev of ['pointerdown','keydown','touchstart'])document.addEventListener(ev,e=>{if(e.target.closest?.('#screensaver')){hideSaver();resetIdle();return}if(!e.target.closest?.('.overlay'))resetIdle()},{passive:true});document.addEventListener('visibilitychange',()=>{if(!document.hidden)refreshStatus(true)});init().catch(e=>{document.body.innerHTML=`<pre style="color:white;padding:15px">NSPIRE V10 käynnistysvirhe\n${esc(e.stack||e.message)}</pre>`})})();
JS

# -----------------------------------------------------------------------------
# Syntaksi- ja rakennetestit ennen aktivointia.
# -----------------------------------------------------------------------------

log "Tarkistetaan V10-paketti"
python3 -m py_compile "$STAGE_ROOT/backend.py"
python3 - <<PY
import json
from pathlib import Path
apps=json.loads(Path('$STAGE_ROOT/static/apps.json').read_text())
assert len(apps) >= 25
ids=[x['id'] for x in apps]
assert len(ids)==len(set(ids))
assert all(x.get('folder') for x in apps)
assert Path('$STAGE_ROOT/static/index.html').stat().st_size > 1000
assert Path('$STAGE_ROOT/static/app.js').stat().st_size > 10000
print('Manifesti ja käyttöliittymärakenne OK:', len(apps), 'sovellusta')
PY
if command -v node >/dev/null 2>&1; then node --check "$STAGE_ROOT/static/app.js"; fi

rm -rf "$APP_ROOT.old"
[[ -d "$APP_ROOT" ]] && mv "$APP_ROOT" "$APP_ROOT.old"
mv "$STAGE_ROOT" "$APP_ROOT"
chmod -R a+rX "$APP_ROOT"
python3 "$APP_ROOT/backend.py" selftest

# -----------------------------------------------------------------------------
# Palautuskomento. Se palauttaa aiemmat kiosk-palvelut eikä sammuta legacy/BMEä.
# -----------------------------------------------------------------------------

cat > /usr/local/sbin/nspire-v10-rollback <<'ROLLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail
DATA=/var/lib/nspire-v10
systemctl disable --now nspire-v10-healthcheck.timer nspire-v10-kiosk.service nspire-v10.service 2>/dev/null || true
if [[ -f "$DATA/previous-services.env" ]]; then
  while IFS='|' read -r service enabled active; do
    [[ -n "$service" ]] || continue
    if systemctl cat "$service" >/dev/null 2>&1; then
      case "$enabled" in enabled|enabled-runtime|static) systemctl enable "$service" >/dev/null 2>&1 || true;; esac
      [[ "$active" == "active" ]] && systemctl start "$service" >/dev/null 2>&1 || true
    fi
  done < "$DATA/previous-services.env"
fi
systemctl daemon-reload
logger -t nspire-v10 "V10 poistettiin käytöstä ja aiempi kioskijärjestelmä palautettiin"
echo "Aiempi NSPIRE-kioskijärjestelmä palautettu."
ROLLBACK
chmod 755 /usr/local/sbin/nspire-v10-rollback

# -----------------------------------------------------------------------------
# Kioskiwrapperi: ensisijaisesti Cage + Cog, varalla Cog tai Chromium/X11.
# -----------------------------------------------------------------------------

cat > /usr/local/bin/nspire-v10-kiosk <<'KIOSK'
#!/usr/bin/env bash
set -Eeuo pipefail
URL="http://127.0.0.1:8775/"
for _ in $(seq 1 45); do curl -fsS "http://127.0.0.1:8775/api/health" >/dev/null 2>&1 && break; sleep 1; done
if command -v cage >/dev/null 2>&1 && command -v cog >/dev/null 2>&1; then
  exec cage -s -r -r -- cog -P fdo "$URL"
elif command -v cog >/dev/null 2>&1; then
  exec cog -P fdo "$URL"
elif command -v chromium-browser >/dev/null 2>&1; then
  export DISPLAY="${DISPLAY:-:0}"
  exec chromium-browser --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble "$URL"
elif command -v chromium >/dev/null 2>&1; then
  export DISPLAY="${DISPLAY:-:0}"
  exec chromium --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble "$URL"
else
  echo "Cage/Cog/Chromium puuttuu" >&2
  exit 1
fi
KIOSK
chmod 755 /usr/local/bin/nspire-v10-kiosk

cat > /etc/systemd/system/nspire-v10.service <<EOF
[Unit]
Description=NSPIRE V10 Daily Driver backend
After=network.target nspire-ui.service nspire-v4.service

[Service]
Type=simple
User=root
WorkingDirectory=$APP_ROOT
ExecStart=/usr/bin/python3 $APP_ROOT/backend.py serve
Restart=on-failure
RestartSec=4
Nice=-2
CPUWeight=700
IOWeight=600
OOMScoreAdjust=-250
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/nspire-v10-kiosk.service <<'EOF'
[Unit]
Description=NSPIRE V10 Cage/Cog kiosk
After=nspire-v10.service network-online.target fb1-desktop.service
Wants=nspire-v10.service

[Service]
Type=simple
User=mavks
Environment=HOME=/home/mavks
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=/usr/local/bin/nspire-v10-kiosk
Restart=on-failure
RestartSec=5
Nice=-4
CPUWeight=900
IOWeight=800
OOMScoreAdjust=-300

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# Rajattu healthcheck: 3 virhettä, 5 min cooldown, turvatila toistuvista restarteista.
# -----------------------------------------------------------------------------

cat > "$APP_ROOT/healthcheck.py" <<'PY'
#!/usr/bin/env python3
import json, subprocess, time, urllib.request
from pathlib import Path
STATE=Path('/var/lib/nspire-v10/healthcheck.json'); SAFE=Path('/var/lib/nspire-v10/safe-mode')
now=int(time.time())
try: state=json.loads(STATE.read_text())
except Exception: state={'failures':0,'last_restart':0,'restart_times':[],'restart_count':0}
healthy=False
try:
    with urllib.request.urlopen('http://127.0.0.1:8775/api/health',timeout=2) as r:
        healthy=r.status==200 and json.loads(r.read().decode()).get('ok') is True
except Exception: pass
kiosk=subprocess.run(['systemctl','is-active','--quiet','nspire-v10-kiosk.service']).returncode==0
if healthy and kiosk:
    state['failures']=0; state['action']='healthy'; state['last_success']=now
else:
    state['failures']=int(state.get('failures',0))+1; state['last_failure']=now; state['action']='failure-recorded'
    if state['failures']>=3 and now-int(state.get('last_restart',0))>=300:
        times=[int(x) for x in state.get('restart_times',[]) if now-int(x)<600]
        times.append(now); state['restart_times']=times; state['restart_count']=int(state.get('restart_count',0))+1
        if len(times)>=3: SAFE.touch(); state['action']='safe-mode'
        else: state['action']='restarted'
        subprocess.run(['systemctl','restart','nspire-v10.service','nspire-v10-kiosk.service'],timeout=45,check=False)
        state['last_restart']=now; state['failures']=0
state['last_check']=now; state['backend_healthy']=healthy; state['kiosk_healthy']=kiosk
STATE.write_text(json.dumps(state,ensure_ascii=False,indent=2))
PY
chmod 755 "$APP_ROOT/healthcheck.py"

cat > /etc/systemd/system/nspire-v10-healthcheck.service <<EOF
[Unit]
Description=NSPIRE V10 limited health check
After=nspire-v10.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $APP_ROOT/healthcheck.py
Nice=15
CPUWeight=10
IOWeight=10
EOF

cat > /etc/systemd/system/nspire-v10-healthcheck.timer <<'EOF'
[Unit]
Description=Run NSPIRE V10 health check

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=20s
Persistent=false

[Install]
WantedBy=timers.target
EOF

# Päivittäinen kevyt varmuuskopio.
cat > /etc/systemd/system/nspire-v10-backup.service <<EOF
[Unit]
Description=NSPIRE V10 daily backup
After=nspire-v10.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $APP_ROOT/backend.py backup
Nice=18
CPUWeight=5
IOWeight=5
EOF
cat > /etc/systemd/system/nspire-v10-backup.timer <<'EOF'
[Unit]
Description=Daily NSPIRE V10 backup
[Timer]
OnBootSec=15min
OnCalendar=daily
RandomizedDelaySec=15min
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

# Käynnistä backend ennen vanhan kioskin pysäyttämistä.
systemctl enable --now nspire-v10.service
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/api/health" | grep -q '"ok": true' || die "V10-backendin terveystesti epäonnistui"

# Vasta terveystestin jälkeen vaihdetaan kioskikäynnistys V10:een.
for service in kiosk-cog.service nspire-kiosk.service; do
  if systemctl cat "$service" >/dev/null 2>&1; then
    systemctl disable --now "$service" >/dev/null 2>&1 || true
  fi
done
systemctl enable --now nspire-v10-kiosk.service nspire-v10-healthcheck.timer nspire-v10-backup.timer
ACTIVATED=1
sleep 7
systemctl is-active --quiet nspire-v10.service || die "nspire-v10.service ei käynnistynyt"
systemctl is-active --quiet nspire-v10-kiosk.service || die "nspire-v10-kiosk.service ei käynnistynyt"
curl -fsS "http://127.0.0.1:$PORT/api/status" >/tmp/nspire-v10-status.json
python3 - <<'PY'
import json
x=json.load(open('/tmp/nspire-v10-status.json'))
assert x['ok'] is True
assert x['version']=='10.0.0'
assert x['config']['bme_always_on'] is True
assert x['config']['ui']['grid_columns']==6
print('V10 lopputarkistus OK:', x['version'], 'profiili', x.get('profile'))
PY

cat > "$DATA_ROOT/CHANGELOG-V10.0.0.txt" <<'EOF'
NSPIRE V10.0.0 Daily Driver Platform

- Uusi itsenäinen, kevyt käyttöliittymä portissa 8775.
- 6x5-etusivu; vain kansiot etusivulla; sovellukset aakkosjärjestyksessä.
- Sovellusmanifestit, haku, suosikit ja viimeksi käytetyt.
- Pysyvä yläpalkki: kuorma, CPU-lämpö, akku, kello.
- Pika-asetukset ja selkeät Teho/Ylläpito/Säästö/Automaattinen-profiilit.
- Latauksessa Teho, akulla Ylläpito, Säästö käsin.
- BME680 pidetään aina käytössä; legacy-sensoripalvelua ei pysäytetä.
- Yksi tapahtumapohjainen näytönsäästäjäajastin.
- Sohva 2 ilman boldauksia, musta näyttö, unikello ja tietonäkymä.
- Yleiset vierityspainikkeet kaikissa vieritettävissä näkymissä.
- Huolto, diagnostiikka, varmuuskopio, turvatila ja rollback.
- Rajattu healthcheck: 3 virhettä, 5 minuutin cooldown, ei restarttisilmukkaa.
- Engineering Pack: yksiköt, materiaalit, kierteet, sovitteet, laakeri, akseli,
  hitsaus, hydrauliikka, sähkö, statiikka, dynamiikka ja lujuusoppi.
- Päivitysasennus säilyttää asetukset; --clean tekee puhtaan V10-asennuksen.
EOF

trap - ERR
log "NSPIRE V${VERSION} ASENNETTU"
echo
printf '%s\n' "V10 käyttöliittymä: http://127.0.0.1:$PORT/"
printf '%s\n' "Varmuuskopio: $BACKUP"
printf '%s\n' "Palautuskomento: sudo nspire-v10-rollback"
printf '%s\n' "Puhdas asennus: sudo bash $SELF --clean"
printf '%s\n' "Anna käyttöliittymälle 15–25 sekuntia käynnistyä."
