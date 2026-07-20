#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="10.1.0"
BASE_COMMIT="3f0996f15984cd641575e83531dcebf598eac190"
BASE_URL="https://raw.githubusercontent.com/mikavahakangas-hue/Pirre/${BASE_COMMIT}/releases/nspire_v10_0_0_daily_driver_platform_all_in_one.sh"
BASE_INSTALLER="/tmp/nspire-v10-base.$$"
V10_ROOT="/opt/nspire-v10"
V101_ROOT="/opt/nspire-v101"
V101_STAGE="/opt/nspire-v101.stage"
V101_DATA="/var/lib/nspire-v101"
V101_BACKUPS="/var/backups/nspire-v101"
V101_PORT="8776"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$V101_BACKUPS/pre-v101-$STAMP"
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; logger -t nspire-v101-installer -- "$*" 2>/dev/null || true; }
die(){ printf '\nVIRHE: %s\n' "$*" >&2; exit 1; }

rollback_on_error(){
  rc=$?
  trap - ERR
  echo
  echo "V10.1-asennus epäonnistui (koodi $rc). Palautetaan V10.0:n käyttöliittymätiedostot."
  if [[ -x /usr/local/sbin/nspire-v101-rollback ]]; then
    /usr/local/sbin/nspire-v101-rollback --installer-failure || true
  fi
  rm -f "$BASE_INSTALLER"
  exit "$rc"
}
trap rollback_on_error ERR
trap 'rm -f "$BASE_INSTALLER"' EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Aja sudo-komennolla: sudo bash $SELF"
for cmd in python3 curl systemctl tar; do command -v "$cmd" >/dev/null 2>&1 || die "$cmd puuttuu"; done
FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
[[ "${FREE_KB:-0}" -ge 250000 ]] || die "Vapaata levytilaa tarvitaan vähintään 250 Mt"

log "NSPIRE V${VERSION} COMPANION & BLACK BOX"
log "Asennetaan ensin versionumerolla lukittu V10.0-pohja"
curl -fL --retry 3 --connect-timeout 15 "$BASE_URL" -o "$BASE_INSTALLER"
bash -n "$BASE_INSTALLER" || die "V10.0-pohja-asentimen Bash-syntaksi ei kelpaa"
bash "$BASE_INSTALLER"

[[ -f "$V10_ROOT/backend.py" ]] || die "V10-backend puuttuu"
[[ -f "$V10_ROOT/static/app.js" ]] || die "V10 app.js puuttuu"
[[ -f "$V10_ROOT/static/apps.json" ]] || die "V10 apps.json puuttuu"

mkdir -p "$V101_DATA" "$V101_BACKUPS" "$BACKUP/files"
chmod 700 "$V101_DATA"
cp -a "$V10_ROOT/backend.py" "$BACKUP/files/backend.py"
cp -a "$V10_ROOT/static/app.js" "$BACKUP/files/app.js"
cp -a "$V10_ROOT/static/apps.json" "$BACKUP/files/apps.json"
cp -a /etc/nspire-v10/config.json "$BACKUP/files/config.json" 2>/dev/null || true
for path in /etc/systemd/system/nspire-v101.service /usr/local/sbin/nspire-v101-rollback; do
  [[ -e "$path" ]] || continue
  mkdir -p "$BACKUP/files$(dirname "$path")"
  cp -a "$path" "$BACKUP/files$path"
done
printf '%s\n' "$BACKUP" > "$V101_DATA/last-install-backup.txt"

cat > /usr/local/sbin/nspire-v101-rollback <<'ROLLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail
DATA=/var/lib/nspire-v101
BACKUP="$(cat "$DATA/last-install-backup.txt" 2>/dev/null || true)"
systemctl disable --now nspire-v101.service 2>/dev/null || true
if [[ -n "$BACKUP" && -d "$BACKUP/files" ]]; then
  [[ -f "$BACKUP/files/backend.py" ]] && cp -a "$BACKUP/files/backend.py" /opt/nspire-v10/backend.py
  [[ -f "$BACKUP/files/app.js" ]] && cp -a "$BACKUP/files/app.js" /opt/nspire-v10/static/app.js
  [[ -f "$BACKUP/files/apps.json" ]] && cp -a "$BACKUP/files/apps.json" /opt/nspire-v10/static/apps.json
  [[ -f "$BACKUP/files/config.json" ]] && cp -a "$BACKUP/files/config.json" /etc/nspire-v10/config.json
fi
systemctl daemon-reload
systemctl restart nspire-v10.service nspire-v10-kiosk.service 2>/dev/null || true
logger -t nspire-v101 "V10.1 poistettiin käytöstä ja V10.0-tiedostot palautettiin"
echo "NSPIRE V10.0:n tiedostot palautettu."
ROLLBACK
chmod 755 /usr/local/sbin/nspire-v101-rollback

rm -rf "$V101_STAGE"
mkdir -p "$V101_STAGE/static"

cat > "$V101_STAGE/companion.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import hmac
import json
import mimetypes
import os
import secrets
import shutil
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from collections import deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

VERSION = "10.1.0"
PORT = 8776
ROOT = Path("/opt/nspire-v101")
STATIC = ROOT / "static"
DATA = Path("/var/lib/nspire-v101")
BACKUPS = Path("/var/backups/nspire-v101")
DB_PATH = DATA / "blackbox.db"
PAIRED_PATH = DATA / "paired-devices.json"
PAIR_PATH = Path("/run/nspire-v101-pair.json")
COMMAND_PATH = DATA / "ui-commands.jsonl"
REPORTS = DATA / "reports"
V10_API = "http://127.0.0.1:8775/api"
V10_APPS = Path("/opt/nspire-v10/static/apps.json")
SAMPLE_SECONDS = 30
RETENTION_SECONDS = 24 * 3600

DATA.mkdir(parents=True, exist_ok=True)
BACKUPS.mkdir(parents=True, exist_ok=True)
REPORTS.mkdir(parents=True, exist_ok=True)
os.chmod(DATA, 0o700)

LOCK = threading.RLock()
CPU_PREV: tuple[int, int] | None = None
SAMPLE_BUFFER: list[tuple[Any, ...]] = []
LAST_RESTARTS: dict[str, int] = {}
STREAKS = {"cpu": 0, "temp": 0, "ram": 0, "swap": 0, "ui_rss": 0, "backend": 0, "bme": 0}
INCIDENT_COOLDOWN: dict[str, int] = {}
COMMAND_SEQ = 0


def run(cmd: list[str], timeout: int = 15) -> subprocess.CompletedProcess[str]:
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
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA temp_store=MEMORY")
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with db() as conn:
        conn.executescript("""
        CREATE TABLE IF NOT EXISTS metrics(
          ts INTEGER PRIMARY KEY,
          cpu REAL, temp REAL, freq INTEGER, ram REAL, swap REAL,
          battery REAL, charging INTEGER, profile TEXT, disk_free_mb REAL,
          ui_rss_mb REAL, backend_ms REAL, bme_age_s REAL,
          v10_restarts INTEGER, kiosk_restarts INTEGER
        );
        CREATE TABLE IF NOT EXISTS incidents(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts INTEGER NOT NULL, kind TEXT NOT NULL, severity TEXT NOT NULL,
          title TEXT NOT NULL, detail TEXT NOT NULL, snapshot_json TEXT
        );
        CREATE TABLE IF NOT EXISTS events(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts INTEGER NOT NULL, kind TEXT NOT NULL, message TEXT NOT NULL, detail_json TEXT
        );
        CREATE INDEX IF NOT EXISTS metrics_ts_idx ON metrics(ts);
        CREATE INDEX IF NOT EXISTS incidents_ts_idx ON incidents(ts);
        """)
    os.chmod(DB_PATH, 0o600)


def json_request(url: str, method: str = "GET", payload: dict[str, Any] | None = None,
                 timeout: float = 4.0) -> tuple[Any, float]:
    started = time.monotonic()
    body = None
    headers = {"User-Agent": "NSPIRE-V10.1"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        data = json.loads(response.read(1024 * 1024).decode("utf-8", "replace"))
    return data, round((time.monotonic() - started) * 1000, 1)


def v10_status() -> tuple[dict[str, Any], float]:
    try:
        data, latency = json_request(V10_API + "/status", timeout=4.0)
        return (data if isinstance(data, dict) else {}), latency
    except Exception:
        return {}, 9999.0


def v10_action(action: str, **extra: Any) -> Any:
    data, _ = json_request(V10_API + "/action", method="POST", payload={"action": action, **extra}, timeout=12)
    if isinstance(data, dict) and data.get("ok") is False:
        raise RuntimeError(str(data.get("error", "V10-toiminto epäonnistui")))
    return data.get("result") if isinstance(data, dict) else data


def cpu_snapshot() -> tuple[int, int]:
    values = [int(x) for x in Path("/proc/stat").read_text().splitlines()[0].split()[1:]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return sum(values), idle


def cpu_percent() -> float:
    global CPU_PREV
    now = cpu_snapshot()
    if CPU_PREV is None:
        CPU_PREV = now
        return 0.0
    total = max(1, now[0] - CPU_PREV[0])
    idle = max(0, now[1] - CPU_PREV[1])
    CPU_PREV = now
    return round(100 * (total - idle) / total, 1)


def temperature() -> float | None:
    try:
        return round(int(Path("/sys/class/thermal/thermal_zone0/temp").read_text()) / 1000, 1)
    except Exception:
        return None


def frequency_mhz() -> int | None:
    vals = []
    for path in Path("/sys/devices/system/cpu").glob("cpu*/cpufreq/scaling_cur_freq"):
        try: vals.append(int(path.read_text()) // 1000)
        except Exception: pass
    return round(sum(vals) / len(vals)) if vals else None


def memory() -> tuple[float, float]:
    info: dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, value = line.split(":", 1)
            info[key] = int(value.strip().split()[0])
    except Exception:
        return 0.0, 0.0
    total = max(1, info.get("MemTotal", 1)); available = info.get("MemAvailable", 0)
    swap_total = info.get("SwapTotal", 0); swap_free = info.get("SwapFree", 0)
    ram = round(100 * (total - available) / total, 1)
    swap = round(100 * (swap_total - swap_free) / swap_total, 1) if swap_total else 0.0
    return ram, swap


def ui_rss_mb() -> float:
    result = run(["ps", "-eo", "comm=,rss="], 5)
    total = 0
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2: continue
        name = parts[0].lower()
        if any(token in name for token in ["cog", "chromium", "chrome", "webkit"]):
            try: total += int(parts[1])
            except Exception: pass
    return round(total / 1024, 1)


def service_restarts(name: str) -> int:
    out = run(["systemctl", "show", name, "-p", "NRestarts", "--value"], 5).stdout.strip()
    try: return int(out)
    except Exception: return 0


def find_timestamp(obj: Any) -> int | None:
    if isinstance(obj, dict):
        for key in ["timestamp", "time", "updated_at", "last_update", "last_success"]:
            value = obj.get(key)
            if isinstance(value, (int, float)) and value > 1_000_000_000:
                return int(value)
        for value in obj.values():
            found = find_timestamp(value)
            if found: return found
    elif isinstance(obj, list):
        for value in obj:
            found = find_timestamp(value)
            if found: return found
    return None


def bme_age() -> float:
    try:
        data, _ = json_request(V10_API + "/sensors", timeout=3)
        if not isinstance(data, dict) or not data.get("ok"):
            return -1.0
        stamp = find_timestamp(data.get("data"))
        return max(0.0, time.time() - stamp) if stamp else 0.0
    except Exception:
        return -1.0


def top_processes() -> list[dict[str, Any]]:
    out = run(["ps", "-eo", "pid,comm,%cpu,%mem,rss,nice", "--sort=-%cpu"], 6).stdout
    rows = []
    for line in out.splitlines()[1:16]:
        parts = line.split(None, 5)
        if len(parts) != 6: continue
        try:
            rows.append({"pid": int(parts[0]), "name": parts[1], "cpu": float(parts[2]),
                         "memory": float(parts[3]), "rss_mb": round(int(parts[4]) / 1024, 1),
                         "nice": int(parts[5])})
        except Exception: pass
    return rows


def service_snapshot() -> list[dict[str, Any]]:
    rows = []
    for name in ["nspire-v10.service", "nspire-v10-kiosk.service", "nspire-v101.service",
                 "nspire-ui.service", "nspire-v4.service"]:
        exists = run(["systemctl", "cat", name], 5).returncode == 0
        if not exists: continue
        rows.append({"name": name,
                     "active": run(["systemctl", "is-active", "--quiet", name], 5).returncode == 0,
                     "restarts": service_restarts(name)})
    return rows


def event(kind: str, message: str, detail: Any = None) -> None:
    with db() as conn:
        conn.execute("INSERT INTO events(ts,kind,message,detail_json) VALUES(?,?,?,?)",
                     (int(time.time()), kind, message, json.dumps(detail, ensure_ascii=False) if detail is not None else None))
        conn.execute("DELETE FROM events WHERE ts < ?", (int(time.time()) - 7 * 86400,))


def recent_metrics(minutes: int = 5) -> list[dict[str, Any]]:
    with db() as conn:
        rows = conn.execute("SELECT * FROM metrics WHERE ts>=? ORDER BY ts", (int(time.time()) - minutes * 60,)).fetchall()
    return [dict(row) for row in rows]


def create_snapshot() -> dict[str, Any]:
    journal = run(["journalctl", "--no-pager", "-n", "80", "-u", "nspire-v10.service",
                   "-u", "nspire-v10-kiosk.service", "-u", "nspire-v101.service"], 12).stdout[-20000:]
    return {"time": int(time.time()), "metrics_5m": recent_metrics(5), "processes": top_processes(),
            "services": service_snapshot(), "journal": journal}


def incident(kind: str, severity: str, title: str, detail: str, snapshot: bool = True) -> None:
    now = int(time.time())
    if now - INCIDENT_COOLDOWN.get(kind, 0) < 1200:
        return
    INCIDENT_COOLDOWN[kind] = now
    snap = json.dumps(create_snapshot(), ensure_ascii=False) if snapshot else None
    with db() as conn:
        conn.execute("INSERT INTO incidents(ts,kind,severity,title,detail,snapshot_json) VALUES(?,?,?,?,?,?)",
                     (now, kind, severity, title, detail, snap))
        ids = [row[0] for row in conn.execute("SELECT id FROM incidents ORDER BY ts DESC LIMIT -1 OFFSET 50")]
        if ids:
            conn.executemany("DELETE FROM incidents WHERE id=?", [(x,) for x in ids])
    event("incident", title, {"kind": kind, "severity": severity})


def threshold(name: str, active: bool, limit: int, title: str, detail: str, severity: str = "warning") -> None:
    STREAKS[name] = STREAKS.get(name, 0) + 1 if active else 0
    if STREAKS[name] >= limit:
        incident(name, severity, title, detail)
        STREAKS[name] = 0


def analyze(sample: dict[str, Any]) -> None:
    threshold("cpu", sample["cpu"] >= 85, 3, "Pitkä korkea CPU-kuorma",
              f"CPU oli {sample['cpu']} % vähintään kolmessa peräkkäisessä mittauksessa.")
    threshold("temp", (sample["temp"] or 0) >= 80, 2, "Prosessori kuumenee",
              f"CPU-lämpötila oli {sample['temp']} °C.", "critical")
    threshold("ram", sample["ram"] >= 90, 2, "RAM lähes täynnä",
              f"RAM-käyttö oli {sample['ram']} %.", "critical")
    threshold("swap", sample["swap"] >= 40, 2, "Swap-käyttö kasvoi suureksi",
              f"Swap-käyttö oli {sample['swap']} %.")
    threshold("ui_rss", sample["ui_rss_mb"] >= 300, 2, "Käyttöliittymä käyttää paljon muistia",
              f"Cog/Chromium/WebKit käytti yhteensä {sample['ui_rss_mb']} Mt muistia.")
    threshold("backend", sample["backend_ms"] >= 1500, 2, "Backend vastaa hitaasti",
              f"V10-backendin vastausaika oli {sample['backend_ms']} ms.")
    threshold("bme", sample["bme_age_s"] < 0 or sample["bme_age_s"] > 300, 3,
              "BME680-mittaus katkesi", f"BME680-mittauksen ikä oli {sample['bme_age_s']} sekuntia.")
    for service, value in [("nspire-v10.service", sample["v10_restarts"]),
                           ("nspire-v10-kiosk.service", sample["kiosk_restarts"])]:
        old = LAST_RESTARTS.get(service, value)
        if value > old:
            incident("restart-" + service, "critical", "Palvelu käynnistyi uudelleen",
                     f"{service}: NRestarts kasvoi arvosta {old} arvoon {value}.")
        LAST_RESTARTS[service] = value


def sample_once() -> dict[str, Any]:
    status, latency = v10_status()
    ram, swap = memory()
    batt = status.get("battery") if isinstance(status.get("battery"), dict) else {}
    usage = shutil.disk_usage("/")
    row = {
        "ts": int(time.time()), "cpu": cpu_percent(), "temp": temperature(), "freq": frequency_mhz(),
        "ram": ram, "swap": swap, "battery": batt.get("percent"),
        "charging": 1 if batt.get("charging") else 0 if batt.get("charging") is False else None,
        "profile": status.get("profile", "unknown"), "disk_free_mb": round(usage.free / 1048576, 1),
        "ui_rss_mb": ui_rss_mb(), "backend_ms": latency, "bme_age_s": bme_age(),
        "v10_restarts": service_restarts("nspire-v10.service"),
        "kiosk_restarts": service_restarts("nspire-v10-kiosk.service"),
    }
    return row


def flush_samples() -> None:
    with LOCK:
        if not SAMPLE_BUFFER: return
        rows = list(SAMPLE_BUFFER); SAMPLE_BUFFER.clear()
    with db() as conn:
        conn.executemany("""INSERT OR REPLACE INTO metrics
          (ts,cpu,temp,freq,ram,swap,battery,charging,profile,disk_free_mb,ui_rss_mb,backend_ms,bme_age_s,v10_restarts,kiosk_restarts)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
          [(x["ts"],x["cpu"],x["temp"],x["freq"],x["ram"],x["swap"],x["battery"],x["charging"],x["profile"],x["disk_free_mb"],x["ui_rss_mb"],x["backend_ms"],x["bme_age_s"],x["v10_restarts"],x["kiosk_restarts"]) for x in rows])
        conn.execute("DELETE FROM metrics WHERE ts < ?", (int(time.time()) - RETENTION_SECONDS,))


def collector() -> None:
    while True:
        started = time.monotonic()
        try:
            row = sample_once()
            analyze(row)
            with LOCK: SAMPLE_BUFFER.append(row)
            if len(SAMPLE_BUFFER) >= 4: flush_samples()
        except Exception as exc:
            event("collector-error", "Black Box -mittaus epäonnistui", {"error": str(exc)})
        delay = max(3.0, SAMPLE_SECONDS - (time.monotonic() - started))
        time.sleep(delay)


def paired() -> list[dict[str, Any]]:
    value = read_json(PAIRED_PATH, [])
    return value if isinstance(value, list) else []


def save_paired(devices: list[dict[str, Any]]) -> None:
    atomic_json(PAIRED_PATH, devices[-12:])


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def new_pair() -> dict[str, Any]:
    pin = f"{secrets.randbelow(1_000_000):06d}"
    state = {"pin_hash": token_hash(pin), "pin": pin, "created": int(time.time()),
             "expires": int(time.time()) + 600}
    atomic_json(PAIR_PATH, state)
    return {"pin": pin, "expires": state["expires"]}


def pair_status(local: bool = False) -> dict[str, Any]:
    state = read_json(PAIR_PATH, {})
    valid = bool(state) and int(state.get("expires", 0)) > time.time()
    result = {"valid": valid, "expires": state.get("expires"), "paired_devices": len(paired())}
    if local and valid: result["pin"] = state.get("pin")
    return result


def confirm_pair(pin: str, name: str) -> dict[str, Any]:
    state = read_json(PAIR_PATH, {})
    if not state or int(state.get("expires", 0)) < time.time():
        raise ValueError("Parituskoodi on vanhentunut")
    if not hmac.compare_digest(token_hash(pin.strip()), str(state.get("pin_hash", ""))):
        raise ValueError("Väärä PIN-koodi")
    token = secrets.token_urlsafe(32)
    devices = paired()
    devices.append({"name": (name or "Puhelin")[:60], "token_hash": token_hash(token),
                    "created": int(time.time()), "last_seen": int(time.time())})
    save_paired(devices)
    try: PAIR_PATH.unlink()
    except Exception: pass
    event("companion", "Uusi Companion-laite paritettiin", {"name": name})
    return {"token": token, "name": name or "Puhelin"}


def authorize(token: str) -> bool:
    if not token: return False
    digest = token_hash(token)
    devices = paired(); changed = False
    for device in devices:
        if hmac.compare_digest(str(device.get("token_hash", "")), digest):
            device["last_seen"] = int(time.time()); changed = True
            if changed: save_paired(devices)
            return True
    return False


def local_address() -> str:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("1.1.1.1", 80)); address = sock.getsockname()[0]; sock.close()
        return address
    except Exception:
        out = run(["hostname", "-I"], 4).stdout.split()
        return out[0] if out else "127.0.0.1"


def queue_command(command: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    global COMMAND_SEQ
    with LOCK:
        COMMAND_SEQ += 1
        row = {"seq": COMMAND_SEQ, "time": int(time.time()), "command": command, "payload": payload or {}}
        with COMMAND_PATH.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        lines = COMMAND_PATH.read_text(encoding="utf-8").splitlines()
        if len(lines) > 200:
            COMMAND_PATH.write_text("\n".join(lines[-150:]) + "\n", encoding="utf-8")
    event("remote-command", command, payload)
    return row


def commands_after(seq: int) -> list[dict[str, Any]]:
    rows = []
    try:
        for line in COMMAND_PATH.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            if int(row.get("seq", 0)) > seq: rows.append(row)
    except Exception: pass
    return rows[-50:]


def metrics(hours: int) -> list[dict[str, Any]]:
    hours = max(1, min(24, hours))
    with db() as conn:
        rows = conn.execute("SELECT * FROM metrics WHERE ts>=? ORDER BY ts", (int(time.time()) - hours * 3600,)).fetchall()
    return [dict(row) for row in rows]


def incidents(limit: int = 30) -> list[dict[str, Any]]:
    with db() as conn:
        rows = conn.execute("SELECT id,ts,kind,severity,title,detail FROM incidents ORDER BY ts DESC LIMIT ?", (limit,)).fetchall()
    return [dict(row) for row in rows]


def automatic_analysis() -> list[str]:
    recent = metrics(1)
    messages = []
    if not recent: return ["Black Box kerää vielä ensimmäisiä mittauksia."]
    avg = lambda key: sum(float(x.get(key) or 0) for x in recent) / max(1, len(recent))
    maximum = lambda key: max(float(x.get(key) or 0) for x in recent)
    if avg("cpu") > 65: messages.append(f"CPU:n tunnin keskiarvo on korkea: {avg('cpu'):.1f} %.")
    if maximum("temp") > 78: messages.append(f"CPU-lämpötila kävi {maximum('temp'):.1f} °C:ssa.")
    if maximum("ram") > 88: messages.append(f"RAM-käyttö nousi {maximum('ram'):.1f} prosenttiin.")
    if maximum("swap") > 35: messages.append(f"Swap-käyttö nousi {maximum('swap'):.1f} prosenttiin.")
    if maximum("ui_rss_mb") > 280: messages.append(f"Käyttöliittymä käytti enimmillään {maximum('ui_rss_mb'):.1f} Mt muistia.")
    if maximum("backend_ms") > 1200: messages.append(f"Backendin hitain vastaus oli {maximum('backend_ms'):.0f} ms.")
    if not messages: messages.append("Viimeisen tunnin aikana ei havaittu selkeää suorituskykyongelmaa.")
    return messages


def create_report() -> Path:
    flush_samples()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = REPORTS / f"nspire-v101-report-{stamp}.json"
    payload = {"version": VERSION, "created": int(time.time()), "analysis": automatic_analysis(),
               "metrics_24h": metrics(24), "incidents": incidents(50), "services": service_snapshot(),
               "processes": top_processes()}
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(path, 0o600)
    event("report", "Companion-raportti luotu", {"path": str(path)})
    return path


def static_file(path: Path) -> tuple[bytes, str]:
    return path.read_bytes(), mimetypes.guess_type(path.name)[0] or "application/octet-stream"


class Handler(BaseHTTPRequestHandler):
    server_version = "NSPIRE-V101"

    def local(self) -> bool:
        return self.client_address[0] in {"127.0.0.1", "::1"}

    def token(self, query: dict[str, list[str]] | None = None) -> str:
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "): return auth.split(None, 1)[1].strip()
        if query: return (query.get("token") or [""])[0]
        return ""

    def send_bytes(self, data: bytes, mime: str, code: int = 200, cache: str = "no-store") -> None:
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers(); self.wfile.write(data)

    def send_json(self, payload: Any, code: int = 200) -> None:
        self.send_bytes(json.dumps(payload, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8", code)

    def body(self) -> dict[str, Any]:
        length = min(1024 * 1024, int(self.headers.get("Content-Length", "0") or 0))
        raw = self.rfile.read(length) if length else b"{}"
        value = json.loads(raw.decode("utf-8") or "{}")
        return value if isinstance(value, dict) else {}

    def need_auth(self, query: dict[str, list[str]] | None = None) -> bool:
        if authorize(self.token(query)): return True
        self.send_json({"ok": False, "error": "Paritus vaaditaan"}, 401)
        return False

    def do_OPTIONS(self) -> None:
        self.send_bytes(b"", "text/plain", 204)

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path); path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        try:
            if path == "/api/health":
                self.send_json({"ok": True, "version": VERSION}); return
            if path == "/api/pair/status":
                self.send_json({"ok": True, **pair_status(False)}); return
            if path == "/api/device/status":
                if not self.local(): self.send_json({"ok": False, "error": "Vain laitteen paikallisnäkymä"}, 403); return
                status = pair_status(True)
                if not status.get("valid"): status.update(new_pair()); status["valid"] = True
                self.send_json({"ok": True, "url": f"http://{local_address()}:{PORT}/", **status}); return
            if path == "/api/ui/commands":
                if not self.local(): self.send_json({"ok": False, "error": "Vain paikallinen UI"}, 403); return
                seq = int((query.get("after") or ["0"])[0])
                rows = commands_after(seq)
                self.send_json({"ok": True, "commands": rows, "last_seq": rows[-1]["seq"] if rows else seq}); return
            if path == "/api/status":
                if not self.need_auth(query): return
                status, latency = v10_status()
                with db() as conn:
                    latest = conn.execute("SELECT * FROM metrics ORDER BY ts DESC LIMIT 1").fetchone()
                self.send_json({"ok": True, "version": VERSION, "v10": status, "latency_ms": latency,
                                "blackbox": dict(latest) if latest else None,
                                "analysis": automatic_analysis(), "incidents": incidents(8)}); return
            if path == "/api/metrics":
                if not self.need_auth(query): return
                hours = int((query.get("hours") or ["1"])[0])
                self.send_json({"ok": True, "hours": hours, "metrics": metrics(hours)}); return
            if path == "/api/incidents":
                if not self.need_auth(query): return
                self.send_json({"ok": True, "incidents": incidents(50), "analysis": automatic_analysis()}); return
            if path == "/api/apps":
                if not self.need_auth(query): return
                self.send_json({"ok": True, "apps": read_json(V10_APPS, [])}); return
            if path == "/api/report/download":
                if not self.need_auth(query): return
                name = Path((query.get("name") or [""])[0]).name
                target = REPORTS / name
                if not target.is_file(): self.send_json({"ok": False, "error": "Raporttia ei löydy"}, 404); return
                self.send_bytes(target.read_bytes(), "application/json", cache="private, no-store"); return
            if path == "/device":
                data, mime = static_file(STATIC / "device.html"); self.send_bytes(data, mime); return
            if path == "/" or path == "/index.html":
                data, mime = static_file(STATIC / "index.html"); self.send_bytes(data, mime); return
            if path == "/manifest.webmanifest":
                data, mime = static_file(STATIC / "manifest.webmanifest"); self.send_bytes(data, mime, cache="public, max-age=3600"); return
            if path.startswith("/static/"):
                rel = Path(path.removeprefix("/static/"))
                if ".." in rel.parts: self.send_json({"ok": False, "error": "Virheellinen polku"}, 400); return
                target = STATIC / rel
                if target.is_file():
                    data, mime = static_file(target); self.send_bytes(data, mime, cache="public, max-age=3600"); return
            self.send_json({"ok": False, "error": "Ei löytynyt"}, 404)
        except Exception as exc:
            event("http-error", "GET epäonnistui", {"path": path, "error": str(exc)})
            self.send_json({"ok": False, "error": str(exc)}, 500)

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path); path = parsed.path
        try:
            data = self.body()
            if path == "/api/device/new-pair":
                if not self.local(): self.send_json({"ok": False, "error": "Vain laitteen paikallisnäkymä"}, 403); return
                self.send_json({"ok": True, **new_pair()}); return
            if path == "/api/pair/confirm":
                result = confirm_pair(str(data.get("pin", "")), str(data.get("name", "Puhelin")))
                self.send_json({"ok": True, **result}); return
            if not self.need_auth(): return
            if path == "/api/mark":
                message = str(data.get("message", "Käyttäjä merkitsi ongelmahetken"))[:200]
                incident("manual-mark-" + str(int(time.time())), "manual", "Manuaalinen ongelmamerkintä", message)
                self.send_json({"ok": True}); return
            if path == "/api/report":
                report = create_report(); self.send_json({"ok": True, "name": report.name}); return
            if path == "/api/action":
                action = str(data.get("action", ""))
                direct = {"profile", "brightness", "wifi", "vnc", "restart_ui", "diagnostics", "backup"}
                remote = {"open_app", "home", "text", "key", "show_saver", "hide_saver", "refresh"}
                if action in direct:
                    extra = {k: v for k, v in data.items() if k != "action"}
                    result = v10_action(action, **extra)
                elif action in remote:
                    result = queue_command(action, {k: v for k, v in data.items() if k != "action"})
                else:
                    raise ValueError("Toiminto ei ole Companionin sallittujen toimintojen listalla")
                self.send_json({"ok": True, "result": result}); return
            self.send_json({"ok": False, "error": "Ei löytynyt"}, 404)
        except Exception as exc:
            event("http-error", "POST epäonnistui", {"path": path, "error": str(exc)})
            self.send_json({"ok": False, "error": str(exc)}, 400)

    def log_message(self, fmt: str, *args: Any) -> None:
        return


def selftest() -> None:
    init_db()
    required = [STATIC / "index.html", STATIC / "device.html", STATIC / "app.js", STATIC / "app.css", STATIC / "manifest.webmanifest"]
    missing = [str(x) for x in required if not x.exists()]
    if missing: raise SystemExit("Puuttuvat tiedostot: " + ", ".join(missing))
    with db() as conn:
        conn.execute("SELECT 1")
    print(json.dumps({"ok": True, "version": VERSION, "files": len(required)}, ensure_ascii=False))


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(); parser.add_argument("command", nargs="?", default="serve")
    args = parser.parse_args()
    if args.command == "selftest": selftest(); return
    if args.command == "sample":
        init_db(); row = sample_once(); print(json.dumps(row, ensure_ascii=False, indent=2)); return
    if args.command != "serve": raise SystemExit("Tuntematon komento")
    init_db()
    if not pair_status().get("valid"): new_pair()
    threading.Thread(target=collector, daemon=True).start()
    event("boot", f"NSPIRE V{VERSION} Companion & Black Box käynnistyi", {"port": PORT})
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
PY
chmod 755 "$V101_STAGE/companion.py"

cat > "$V101_STAGE/static/index.html" <<'HTML'
<!doctype html><html lang="fi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><meta name="theme-color" content="#07101a"><title>NSPIRE Companion</title><link rel="manifest" href="/manifest.webmanifest"><link rel="stylesheet" href="/static/app.css"></head>
<body><main id="app"><section id="pairView" class="screen"><div class="hero"><span class="logo">N10</span><div><h1>NSPIRE Companion</h1><p>Yhdistä puhelin laitteen näyttämällä PIN-koodilla.</p></div></div><div class="card"><label>Laitteen nimi<input id="deviceName" value="Mikan puhelin"></label><label>Kuusinumeroinen PIN<input id="pin" inputmode="numeric" maxlength="6" placeholder="000000"></label><button id="pairBtn" class="primary">Parita puhelin</button><pre id="pairOut" class="output"></pre></div></section>
<section id="dashView" class="screen hidden"><header><div><b>NSPIRE</b><small>Companion & Black Box</small></div><span id="liveDot" class="dot"></span><button id="refreshBtn">↻</button></header><nav><button data-tab="status" class="active">Tila</button><button data-tab="remote">Ohjaus</button><button data-tab="blackbox">Black Box</button><button data-tab="service">Huolto</button></nav>
<div id="statusTab" class="tab active"><div id="statusCards" class="cards"></div><section class="card"><h2>Automaattinen arvio</h2><div id="analysis"></div></section><section class="card"><h2>Pikatoiminnot</h2><div class="grid2"><button data-profile="auto">Automaattinen</button><button data-profile="performance">Teho</button><button data-profile="maintenance">Ylläpito</button><button data-profile="saver">Säästö</button></div><label>Kirkkaus<input id="brightness" type="range" min="1" max="100"><output id="brightnessOut">--%</output></label></section></div>
<div id="remoteTab" class="tab"><section class="card"><h2>Avaa Nspiressä</h2><select id="appSelect"></select><button id="openAppBtn" class="primary">Avaa sovellus</button><button id="homeBtn">Etusivulle</button></section><section class="card"><h2>Puhelinnäppäimistö</h2><textarea id="remoteText" rows="4" placeholder="Kirjoita tähän ja lähetä aktiiviseen kenttään"></textarea><div class="grid2"><button id="sendText">Lähetä teksti</button><button id="clearText">Tyhjennä</button></div><div class="keys"><button data-key="ArrowUp">↑</button><button data-key="Escape">Esc</button><button data-key="Enter">Enter</button><button data-key="Backspace">⌫</button><button data-key="ArrowLeft">←</button><button data-key="ArrowDown">↓</button><button data-key="ArrowRight">→</button><button data-key="Tab">Tab</button></div></section><section class="card"><h2>Näyttö</h2><div class="grid2"><button data-action="show_saver">Näytönsäästäjä</button><button data-action="hide_saver">Herätä näyttö</button><button data-action="brightness" data-value="1">Näyttö pois</button><button data-action="refresh">Päivitä UI</button></div></section></div>
<div id="blackboxTab" class="tab"><section class="card"><div class="row"><h2>Historia</h2><select id="hours"><option value="1">1 h</option><option value="6">6 h</option><option value="24">24 h</option></select></div><canvas id="chart" width="900" height="360"></canvas><div class="legend"><span>CPU</span><span>Lämpö</span><span>RAM</span><span>Swap</span></div></section><section class="card"><h2>Havaitut häiriöt</h2><div id="incidents"></div><button id="markBtn" class="warn">Merkitse ongelma nyt</button></section></div>
<div id="serviceTab" class="tab"><section class="card"><h2>Huolto</h2><div class="grid2"><button data-direct="diagnostics">Luo diagnostiikka</button><button data-direct="backup">Varmuuskopio</button><button data-direct="restart_ui">UI uudelleen</button><button id="reportBtn">Luo Black Box -raportti</button></div><button id="downloadBtn" class="primary hidden">Lataa raportti</button><pre id="serviceOut" class="output"></pre></section><section class="card"><h2>Yhteys</h2><p>Toiminnot toimivat vain paikallisverkossa paritetulla laitteella. Token on tallennettu tämän selaimen paikalliseen tallennukseen.</p><button id="forgetBtn" class="danger">Unohda paritus tästä puhelimesta</button></section></div></section></main><script src="/static/app.js"></script></body></html>
HTML

cat > "$V101_STAGE/static/device.html" <<'HTML'
<!doctype html><html lang="fi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Companion-paritus</title><link rel="stylesheet" href="/static/app.css"></head><body class="device"><main class="device-card"><h1>Puhelimen Companion</h1><p>Avaa puhelimella sama osoite ja syötä PIN.</p><div id="url" class="big">Haetaan…</div><div id="pinBox" class="pin">------</div><p id="expires"></p><button id="newPin" class="primary">Luo uusi PIN</button><p>PIN on voimassa 10 minuuttia. Parituksen jälkeen puhelin saa laitekohtaisen tunnisteen.</p></main><script>async function load(){let x=await fetch('/api/device/status').then(r=>r.json());url.textContent=x.url;pinBox.textContent=x.pin||'------';expires.textContent=x.expires?'Voimassa noin '+Math.max(0,Math.ceil((x.expires-Date.now()/1000)/60))+' min':''}newPin.onclick=async()=>{await fetch('/api/device/new-pair',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});load()};load();setInterval(load,30000);</script></body></html>
HTML

cat > "$V101_STAGE/static/app.css" <<'CSS'
:root{--bg:#050a10;--surface:#101a25;--surface2:#172535;--line:#2e455e;--text:#f2f6f9;--muted:#9eb0c0;--accent:#5dbbff;--good:#66d395;--warn:#ffd166;--bad:#ff7676}*{box-sizing:border-box}html,body{margin:0;min-height:100%;background:linear-gradient(180deg,#03070b,var(--bg));color:var(--text);font-family:system-ui,-apple-system,sans-serif}button,input,select,textarea{font:inherit}.hidden{display:none!important}#app{max-width:760px;margin:auto;padding:12px}.screen{min-height:100vh}.hero{display:flex;align-items:center;gap:12px;padding:32px 4px 18px}.logo{width:64px;height:64px;border-radius:18px;display:grid;place-items:center;background:linear-gradient(145deg,#1478bf,#52beff);font-size:25px;font-weight:900}.hero h1{margin:0}.hero p{margin:5px 0;color:var(--muted)}header{position:sticky;top:0;z-index:10;display:flex;align-items:center;gap:9px;background:#050a10ed;padding:10px 2px;border-bottom:1px solid var(--line)}header div{display:grid}header small{color:var(--muted)}header button{margin-left:auto}.dot{width:10px;height:10px;border-radius:50%;background:var(--bad)}.dot.live{background:var(--good);box-shadow:0 0 10px var(--good)}nav{display:grid;grid-template-columns:repeat(4,1fr);gap:5px;position:sticky;top:59px;z-index:9;background:#050a10ed;padding:7px 0}nav button,.card button,header button{min-height:42px;border:1px solid var(--line);border-radius:10px;background:var(--surface2);color:var(--text);padding:7px}nav button.active{border-color:var(--accent);color:var(--accent)}.tab{display:none;padding-top:7px}.tab.active{display:block}.card{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:12px;margin:9px 0;box-shadow:0 7px 24px #0007}.card h2{font-size:17px;margin:0 0 10px;color:var(--accent)}label{display:grid;gap:5px;margin:10px 0;color:var(--muted)}input,select,textarea{width:100%;border:1px solid var(--line);border-radius:10px;background:#08111a;color:#fff;padding:10px}textarea{resize:vertical}.primary{background:#116aa6!important;border-color:#3db8ff!important}.warn{border-color:#9d7825!important;color:var(--warn)!important}.danger{border-color:#773b43!important;color:#ffb0b0!important}.cards{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.metric{background:var(--surface);border:1px solid var(--line);border-radius:13px;padding:10px;min-width:0}.metric small{display:block;color:var(--muted)}.metric b{display:block;font-size:24px;overflow:hidden;text-overflow:ellipsis}.grid2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px}.row{display:flex;align-items:center;justify-content:space-between;gap:8px}.row select{width:auto}.keys{display:grid;grid-template-columns:repeat(4,1fr);gap:7px;margin-top:9px}.keys button{font-size:18px}.output{white-space:pre-wrap;overflow:auto;max-height:230px;background:#030609;border:1px solid #1c2b3a;border-radius:9px;padding:9px;color:#cbd8e2}.analysis-line{padding:7px;border-left:3px solid var(--accent);background:#09121b;margin:5px 0}.incident{border-bottom:1px solid var(--line);padding:8px 0}.incident b{display:block}.incident small{color:var(--muted)}canvas{display:block;width:100%;height:240px;background:#050b11;border-radius:9px;border:1px solid #1c2b3a}.legend{display:flex;gap:12px;flex-wrap:wrap;color:var(--muted);font-size:12px}.big{font-size:20px;word-break:break-all;background:#06101a;padding:10px;border-radius:9px}.pin{font:700 58px/1.2 ui-monospace,monospace;letter-spacing:8px;text-align:center;color:var(--warn);margin:20px 0}.device{display:grid;place-items:center;min-height:100vh;padding:12px}.device-card{width:min(620px,96vw);background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:18px}@media(min-width:600px){.cards{grid-template-columns:repeat(4,minmax(0,1fr))}}
CSS

cat > "$V101_STAGE/static/app.js" <<'JS'
(()=>{'use strict';
const S={token:localStorage.getItem('n101-token')||'',status:null,metrics:[],apps:[],report:null,timer:null};
const $=q=>document.querySelector(q), $$=q=>[...document.querySelectorAll(q)];
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function api(path,opt={}){const headers={...(opt.headers||{})};if(S.token)headers.Authorization='Bearer '+S.token;if(opt.body&&!headers['Content-Type'])headers['Content-Type']='application/json';const r=await fetch(path,{...opt,headers});const x=await r.json();if(!r.ok||x.ok===false)throw Error(x.error||'Virhe');return x}
function showDash(){pairView.classList.add('hidden');dashView.classList.remove('hidden');loadApps();refresh(true);clearInterval(S.timer);S.timer=setInterval(()=>{if(!document.hidden)refresh()},5000)}
function showPair(){dashView.classList.add('hidden');pairView.classList.remove('hidden')}
function fmt(v,s=''){return v===null||v===undefined?'--':`${v}${s}`}
function cards(rows){statusCards.innerHTML=rows.map(([a,b])=>`<div class="metric"><small>${esc(a)}</small><b>${esc(b)}</b></div>`).join('')}
async function refresh(force=false){try{const x=await api('/api/status');S.status=x;liveDot.classList.add('live');const v=x.v10||{},b=v.battery||{},bb=x.blackbox||{};cards([['Akku',(b.charging?'⚡ ':'')+fmt(b.percent,'%')],['CPU',fmt(bb.cpu??v.cpu_percent,'%')],['Lämpö',fmt(bb.temp??v.temperature_c,'°')],['RAM',fmt(bb.ram??v.ram_percent,'%')],['Swap',fmt(bb.swap??v.swap_percent,'%')],['UI-muisti',fmt(bb.ui_rss_mb,' Mt')],['Vaste',fmt(bb.backend_ms,' ms')],['Profiili',v.profile||'--']]);analysis.innerHTML=(x.analysis||[]).map(t=>`<div class="analysis-line">${esc(t)}</div>`).join('');brightness.value=v.brightness??50;brightnessOut.value=fmt(v.brightness,'%');renderIncidents(x.incidents||[])}catch(e){liveDot.classList.remove('live');if(e.message.includes('Paritus')){S.token='';localStorage.removeItem('n101-token');showPair()}}}
async function loadApps(){try{const x=await api('/api/apps');S.apps=(x.apps||[]).sort((a,b)=>a.name.localeCompare(b.name,'fi'));appSelect.innerHTML=S.apps.map(a=>`<option value="${esc(a.id)}">${esc(a.folder)} — ${esc(a.name)}</option>`).join('')}catch(e){}}
function renderIncidents(rows){incidents.innerHTML=rows.length?rows.map(x=>`<div class="incident"><b>${esc(x.title)}</b><small>${new Date(x.ts*1000).toLocaleString('fi-FI')} · ${esc(x.severity)}</small><p>${esc(x.detail)}</p></div>`).join(''):'<p>Ei tallennettuja häiriöitä.</p>'}
async function action(name,extra={}){return api('/api/action',{method:'POST',body:JSON.stringify({action:name,...extra})})}
async function loadMetrics(){const h=Number(hours.value||1);const x=await api('/api/metrics?hours='+h);S.metrics=x.metrics||[];drawChart()}
function drawChart(){const c=chart,ctx=c.getContext('2d'),d=S.metrics;ctx.clearRect(0,0,c.width,c.height);ctx.fillStyle='#050b11';ctx.fillRect(0,0,c.width,c.height);if(d.length<2){ctx.fillStyle='#9eb0c0';ctx.font='25px system-ui';ctx.fillText('Mittauksia ei vielä ole riittävästi',30,60);return}ctx.strokeStyle='#21364a';ctx.lineWidth=1;for(let i=0;i<=4;i++){const y=20+i*(c.height-40)/4;ctx.beginPath();ctx.moveTo(35,y);ctx.lineTo(c.width-10,y);ctx.stroke()}const series=[['cpu','#5dbbff',100],['temp','#ff9a68',100],['ram','#66d395',100],['swap','#d599ff',100]];for(const [key,color,max] of series){ctx.strokeStyle=color;ctx.lineWidth=3;ctx.beginPath();d.forEach((x,i)=>{const px=35+i*(c.width-50)/(d.length-1),py=c.height-20-Math.max(0,Math.min(max,Number(x[key]||0)))*(c.height-40)/max;i?ctx.lineTo(px,py):ctx.moveTo(px,py)});ctx.stroke()}ctx.fillStyle='#9eb0c0';ctx.font='18px system-ui';ctx.fillText('100',2,25);ctx.fillText('0',16,c.height-18)}
async function downloadReport(){const r=await fetch('/api/report/download?name='+encodeURIComponent(S.report),{headers:{Authorization:'Bearer '+S.token}});if(!r.ok)throw Error('Raportin lataus epäonnistui');const blob=await r.blob(),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=S.report;a.click();setTimeout(()=>URL.revokeObjectURL(url),2000)}
pairBtn.onclick=async()=>{try{const x=await api('/api/pair/confirm',{method:'POST',body:JSON.stringify({pin:pin.value,name:deviceName.value})});S.token=x.token;localStorage.setItem('n101-token',S.token);pairOut.textContent='Paritus onnistui.';showDash()}catch(e){pairOut.textContent=e.message}};
refreshBtn.onclick=()=>refresh(true);$$('nav button').forEach(b=>b.onclick=()=>{$$('nav button').forEach(x=>x.classList.toggle('active',x===b));$$('.tab').forEach(x=>x.classList.toggle('active',x.id===b.dataset.tab+'Tab'));if(b.dataset.tab==='blackbox')loadMetrics()});$$('[data-profile]').forEach(b=>b.onclick=()=>action('profile',{profile:b.dataset.profile}).then(()=>refresh(true)));brightness.onchange=()=>action('brightness',{value:Number(brightness.value)}).then(()=>refresh(true));openAppBtn.onclick=()=>action('open_app',{id:appSelect.value});homeBtn.onclick=()=>action('home');sendText.onclick=()=>action('text',{text:remoteText.value});clearText.onclick=()=>remoteText.value='';$$('[data-key]').forEach(b=>b.onclick=()=>action('key',{key:b.dataset.key}));$$('[data-action]').forEach(b=>b.onclick=()=>action(b.dataset.action,b.dataset.value?{value:Number(b.dataset.value)}:{}));hours.onchange=loadMetrics;markBtn.onclick=async()=>{const message=prompt('Miltä laite tuntuu juuri nyt?','Laite tahmaa');if(message!==null){await api('/api/mark',{method:'POST',body:JSON.stringify({message})});await refresh(true);await loadMetrics()}};$$('[data-direct]').forEach(b=>b.onclick=async()=>{try{const x=await action(b.dataset.direct);serviceOut.textContent=JSON.stringify(x,null,2)}catch(e){serviceOut.textContent=e.message}});reportBtn.onclick=async()=>{try{const x=await api('/api/report',{method:'POST',body:'{}'});S.report=x.name;serviceOut.textContent='Raportti valmis: '+x.name;downloadBtn.classList.remove('hidden')}catch(e){serviceOut.textContent=e.message}};downloadBtn.onclick=()=>downloadReport().catch(e=>serviceOut.textContent=e.message);forgetBtn.onclick=()=>{localStorage.removeItem('n101-token');location.reload()};document.addEventListener('visibilitychange',()=>{if(!document.hidden&&S.token)refresh(true)});if(S.token)showDash();else showPair();
})();
JS

cat > "$V101_STAGE/static/manifest.webmanifest" <<'JSON'
{"name":"NSPIRE Companion","short_name":"NSPIRE","start_url":"/","display":"standalone","background_color":"#050a10","theme_color":"#07101a","description":"NSPIRE V10.1 Companion and Black Box"}
JSON

python3 -m py_compile "$V101_STAGE/companion.py"
python3 "$V101_STAGE/companion.py" selftest
if command -v node >/dev/null 2>&1; then node --check "$V101_STAGE/static/app.js"; fi

log "Lisätään Companion-sovellus V10:n sovellusmanifestiin ja etäohjaussiltaan"
python3 - "$V10_ROOT/static/apps.json" "$V10_ROOT/static/app.js" "$V10_ROOT/backend.py" <<'PY'
from pathlib import Path
import json, sys
apps_path, js_path, backend_path = map(Path, sys.argv[1:])
apps=json.loads(apps_path.read_text(encoding='utf-8'))
apps=[x for x in apps if x.get('id')!='companion']
apps.append({"id":"companion","name":"Puhelimen Companion","folder":"Verkko","icon":"📱","type":"web","url":"http://127.0.0.1:8776/device"})
apps_path.write_text(json.dumps(apps,ensure_ascii=False,indent=2),encoding='utf-8')

js=js_path.read_text(encoding='utf-8')
marker="/* NSPIRE V10.1 COMPANION BRIDGE */"
if marker not in js:
    needle="document.addEventListener('visibilitychange',()=>{if(!document.hidden)refreshStatus(true)});init().catch"
    assert needle in js, 'V10 app.js -lisäyskohdetta ei löytynyt'
    bridge=r'''/* NSPIRE V10.1 COMPANION BRIDGE */
let n101Seq=0;
function n101InsertText(text){const el=document.activeElement;if(el&&(el.tagName==='INPUT'||el.tagName==='TEXTAREA')){const start=el.selectionStart??el.value.length,end=el.selectionEnd??start;el.setRangeText(String(text),start,end,'end');el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return true}return false}
function n101Key(key){const el=document.activeElement||document.body;el.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));if(key==='Backspace'&&el&&(el.tagName==='INPUT'||el.tagName==='TEXTAREA')){const p=el.selectionStart??el.value.length;if(p>0)el.setRangeText('',p-1,p,'end');el.dispatchEvent(new Event('input',{bubbles:true}))}else if(key==='Enter'&&el&&(el.tagName==='INPUT'||el.tagName==='TEXTAREA')){n101InsertText('\n')}el.dispatchEvent(new KeyboardEvent('keyup',{key,bubbles:true,cancelable:true}))}
async function n101Poll(){try{const r=await fetch('http://127.0.0.1:8776/api/ui/commands?after='+n101Seq,{cache:'no-store'});const x=await r.json();for(const row of x.commands||[]){n101Seq=Math.max(n101Seq,Number(row.seq)||0);const c=row.command,p=row.payload||{};if(c==='open_app')openAppById(String(p.id||''));else if(c==='home')home();else if(c==='text')n101InsertText(p.text||'');else if(c==='key')n101Key(p.key||'');else if(c==='show_saver')showSaver('Companion');else if(c==='hide_saver')hideSaver();else if(c==='refresh')location.reload()}n101Seq=Math.max(n101Seq,Number(x.last_seq)||0)}catch(e){}}
setInterval(n101Poll,1200);n101Poll();
'''
    js=js.replace(needle,bridge+needle)
js_path.write_text(js,encoding='utf-8')

backend=backend_path.read_text(encoding='utf-8')
backend=backend.replace('VERSION = "10.0.0"','VERSION = "10.1.0"',1)
backend_path.write_text(backend,encoding='utf-8')
PY

python3 -m py_compile "$V10_ROOT/backend.py"
python3 - <<PY
import json
apps=json.load(open('$V10_ROOT/static/apps.json'))
assert sum(1 for x in apps if x.get('id')=='companion')==1
assert any(x.get('url')=='http://127.0.0.1:8776/device' for x in apps)
text=open('$V10_ROOT/static/app.js').read()
assert 'NSPIRE V10.1 COMPANION BRIDGE' in text
print('V10.1 manifesti ja Companion-silta OK')
PY
if command -v node >/dev/null 2>&1; then node --check "$V10_ROOT/static/app.js"; fi

rm -rf "$V101_ROOT.old"
[[ -d "$V101_ROOT" ]] && mv "$V101_ROOT" "$V101_ROOT.old"
mv "$V101_STAGE" "$V101_ROOT"
chmod -R a+rX "$V101_ROOT"
chmod 755 "$V101_ROOT/companion.py"

cat > /etc/systemd/system/nspire-v101.service <<EOF
[Unit]
Description=NSPIRE V10.1 Companion and Black Box
After=network-online.target nspire-v10.service
Wants=nspire-v10.service

[Service]
Type=simple
User=root
WorkingDirectory=$V101_ROOT
ExecStart=/usr/bin/python3 $V101_ROOT/companion.py serve
Restart=on-failure
RestartSec=5
Nice=8
CPUWeight=80
IOWeight=40
MemoryHigh=140M
MemoryMax=190M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$V101_DATA $V101_BACKUPS /run /home/mavks
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nspire-v101.service
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$V101_PORT/api/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$V101_PORT/api/health" | grep -q '"ok": true' || die "Companion-palvelun terveystesti epäonnistui"
python3 "$V101_ROOT/companion.py" sample >/tmp/nspire-v101-sample.json
python3 - <<'PY'
import json
x=json.load(open('/tmp/nspire-v101-sample.json'))
required={'ts','cpu','ram','swap','ui_rss_mb','backend_ms','bme_age_s'}
assert required <= set(x)
print('Black Box -mittaus OK:', x['cpu'], '% CPU,', x['ram'], '% RAM')
PY
systemctl restart nspire-v10.service nspire-v10-kiosk.service
sleep 7
systemctl is-active --quiet nspire-v10.service || die "V10-backend ei käynnistynyt V10.1-versiona"
systemctl is-active --quiet nspire-v10-kiosk.service || die "V10-kioski ei käynnistynyt"
systemctl is-active --quiet nspire-v101.service || die "Companion-palvelu ei käynnistynyt"

cat > "$V101_DATA/CHANGELOG-V10.1.0.txt" <<'EOF'
NSPIRE V10.1.0 Companion & Black Box

COMPANION
- Puhelimella avattava lähiverkon hallintanäkymä portissa 8776.
- Kuusinumeroinen, 10 minuuttia voimassa oleva PIN-paritus.
- Laitekohtainen satunnainen token tallennetaan vain puhelimen selaimeen.
- Akku, CPU, lämpötila, RAM, swap, UI-muisti, vaste ja virtaprofiili.
- Sovelluksen avaaminen, etusivu, virtaprofiili, kirkkaus ja näytönsäästäjä.
- Puhelinnäppäimistö: teksti sekä Enter/Esc/Backspace/nuolet/Tab.
- Diagnostiikka, varmuuskopio, UI:n uudelleenkäynnistys ja raportin lataus.

BLACK BOX
- SQLite WAL -tietokanta ja 30 sekunnin mittausväli.
- Neljän mittauksen eräkirjoitus SD-kortin säästämiseksi.
- Vain viimeiset 24 tuntia mittareita.
- CPU, lämpö, kellotaajuus, RAM, swap, akku, levytila, UI-RSS, backend-vaste,
  BME680-mittauksen ikä ja palveluiden restart-laskurit.
- Automaattinen ongelma-analyysi ja häiriöhetken tilannekuva.
- Tilannekuvassa prosessit, palvelut, loki ja edeltävän viiden minuutin mittaukset.
- Enintään 50 häiriötä; Black Box ei koskaan käynnistä palveluita uudelleen.
EOF

trap - ERR
log "NSPIRE V${VERSION} ASENNETTU"
ADDRESS="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$ADDRESS" ]] || ADDRESS="nspire.local"
echo
echo "Puhelimen Companion: http://${ADDRESS}:${V101_PORT}/"
echo "Paritus-PIN löytyy Nspiren Verkko-kansiosta: Puhelimen Companion"
echo "Black Box alkaa kerätä mittauksia 30 sekunnin välein."
echo "Palautus V10.0:aan: sudo nspire-v101-rollback"
echo "Anna käyttöliittymälle noin 15–25 sekuntia käynnistyä."
