#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="9.9.0"
BASE_COMMIT="94e35ac44baedb0dcebc0f82844c97e0478c8f4b"
BASE_URL="https://raw.githubusercontent.com/mikavahakangas-hue/Pirre/${BASE_COMMIT}/releases/nspire_v9_8_0_all_in_one_installer.sh"
INSTALL_ROOT="/opt/nspire-v98"
STATE_ROOT="/var/lib/nspire-v98"
CONFIG="/etc/nspire-v98/config.json"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "VIRHE: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Aja sudo-komennolla: sudo bash $0"
command -v python3 >/dev/null || die "python3 puuttuu"
command -v curl >/dev/null || die "curl puuttuu"
command -v systemctl >/dev/null || die "systemd puuttuu"

log "NSPIRE V${VERSION} COMPLETE SUITE"
log "Asennetaan ensin varmennettu V9.8-vakauspohja"

TMP_BASE="$(mktemp /tmp/nspire-v98-base.XXXXXX.sh)"
trap 'rm -f "$TMP_BASE"' EXIT
curl -fL --retry 3 --connect-timeout 15 "$BASE_URL" -o "$TMP_BASE"
bash -n "$TMP_BASE" || die "V9.8-pohja-asentimen syntaksi ei kelpaa"
bash "$TMP_BASE"

[[ -f "$INSTALL_ROOT/nspire98.py" ]] || die "V9.8-pohjan hallintapalvelua ei löytynyt"
INDEX="$(cat "$STATE_ROOT/index-path.txt" 2>/dev/null || true)"
[[ -n "$INDEX" && -f "$INDEX" ]] || die "Käyttöliittymän index.html ei löytynyt"
WEB_ROOT="$(dirname "$INDEX")"
ASSET_ROOT="$WEB_ROOT/nspire98"
mkdir -p "$ASSET_ROOT"

STAMP="$(date +%Y%m%d-%H%M%S)"
EXTRA_BACKUP="/var/backups/nspire-v98/pre-v99-$STAMP"
mkdir -p "$EXTRA_BACKUP"
cp -a "$INSTALL_ROOT/nspire98.py" "$EXTRA_BACKUP/nspire98.py"
cp -a "$INDEX" "$EXTRA_BACKUP/index.html"
cp -a "$CONFIG" "$EXTRA_BACKUP/config.json" 2>/dev/null || true
cp -a "$ASSET_ROOT" "$EXTRA_BACKUP/nspire98-assets" 2>/dev/null || true
printf '%s\n' "$EXTRA_BACKUP" > "$STATE_ROOT/last-v99-backup.txt"

log "Laajennetaan virtaprofiilien, äänen, kameran ja näytönsäästäjän säätöjä"

python3 - "$INSTALL_ROOT/nspire98.py" "$CONFIG" <<'PY'
from pathlib import Path
import json, sys, re

py_path=Path(sys.argv[1]); config_path=Path(sys.argv[2])
text=py_path.read_text(encoding='utf-8')
text=text.replace('VERSION = "9.8.0"','VERSION = "9.9.0"')

marker='# NSPIRE V9.9 COMPLETE PROFILE EXTENSION'
if marker not in text:
    extension=r'''
# NSPIRE V9.9 COMPLETE PROFILE EXTENSION

def _save_config(config: dict) -> None:
    config["version"] = "9.9.0"
    config["bme_always_on"] = True
    atomic_json(CONFIG, config)


def _toggle_vnc(enabled: bool) -> list[str]:
    changed = []
    for name in ["vncserver-x11-serviced.service", "x11vnc.service", "wayvnc.service"]:
        if run(["systemctl", "cat", name], 5).returncode == 0:
            run(["systemctl", "enable" if enabled else "disable", "--now", name], 20)
            changed.append(name)
    return changed


def _apply_aux_profile(profile: dict) -> None:
    if shutil.which("nmcli"):
        run(["nmcli", "radio", "wifi", "on" if bool(profile.get("wifi", True)) else "off"], 15)
    _toggle_vnc(bool(profile.get("vnc", True)))
    if shutil.which("amixer"):
        volume = max(0, min(100, int(profile.get("audio", 70))))
        run(["amixer", "-q", "sset", "Master", f"{volume}%"], 10)
    atomic_json(STATE / "camera-policy.json", {
        "enabled": bool(profile.get("camera", True)),
        "time": int(time.time())
    })


def select_profile(requested: str) -> dict:
    if requested not in {"auto", "performance", "maintenance", "saver"}:
        raise ValueError("Tuntematon profiili")
    config = read_json(CONFIG, {})
    config["manual_profile"] = requested
    _save_config(config)
    return apply_profile(requested)


def save_profile_settings(name: str, updates: dict) -> dict:
    if name not in {"performance", "maintenance", "saver"}:
        raise ValueError("Tuntematon profiili")
    config = read_json(CONFIG, {})
    profiles = config.setdefault("profiles", {})
    current = profiles.setdefault(name, {})
    allowed = {
        "governor": str, "brightness": int, "metric_seconds": int,
        "audio": int, "screensaver_seconds": int,
        "animations": bool, "wifi": bool, "vnc": bool, "camera": bool
    }
    for key, cast in allowed.items():
        if key in updates:
            value = updates[key]
            if cast is bool: value = bool(value)
            else: value = cast(value)
            if key in {"brightness", "audio"}: value = max(0, min(100, value))
            if key == "metric_seconds": value = max(4, min(60, value))
            if key == "screensaver_seconds": value = max(20, min(7200, value))
            current[key] = value
    _save_config(config)
    if profile_name() == name:
        return apply_profile(name)
    return {"profile": name, "settings": current}
'''
    text=text.replace('\nclass Handler(BaseHTTPRequestHandler):',extension+'\n\nclass Handler(BaseHTTPRequestHandler):')

# Lisää lisäasetusten soveltaminen aktiivisen profiilin yhteyteen.
needle='''    set_brightness(int(profile.get("brightness", 60)))
    atomic_json(STATE / "active-profile.json", {"profile": name, "time": int(time.time())})'''
replacement='''    set_brightness(int(profile.get("brightness", 60)))
    _apply_aux_profile(profile) if "_apply_aux_profile" in globals() else None
    if profile.get("screensaver_seconds"):
        config = read_json(CONFIG, {})
        config.setdefault("screensaver", {})["delay_seconds"] = int(profile["screensaver_seconds"])
        config["bme_always_on"] = True
        atomic_json(CONFIG, config)
    atomic_json(STATE / "active-profile.json", {"profile": name, "time": int(time.time())})'''
text=text.replace(needle,replacement)

# Profiilin valinta tallennetaan. Lisäasetukset voidaan tallentaa käyttöliittymästä.
text=text.replace('''            elif action == "profile": result = apply_profile(str(data.get("profile", "auto")))''','''            elif action == "profile": result = select_profile(str(data.get("profile", "auto")))
            elif action == "save_profile":
                result = save_profile_settings(str(data.get("profile", "maintenance")), dict(data.get("settings") or {}))''')

# Automaattiajastin ei kirjoita kirkkautta uudelleen 30 sekunnin välein.
text=re.sub(r'''def auto_power\(\) -> None:\n    config = read_json\(CONFIG, \{\}\)\n    manual = config.get\("manual_profile", "auto"\)\n    if manual in \{"performance", "maintenance", "saver"\}: apply_profile\(manual\)\n    else: apply_profile\("auto"\)''', '''def auto_power() -> None:
    config = read_json(CONFIG, {})
    manual = config.get("manual_profile", "auto")
    if manual in {"performance", "maintenance", "saver"}:
        desired = manual
    else:
        desired = "performance" if battery().get("charging") is not False else "maintenance"
    if profile_name() != desired:
        apply_profile(desired)''', text)

py_path.write_text(text,encoding='utf-8')

config=json.loads(config_path.read_text(encoding='utf-8')) if config_path.exists() else {}
config['version']='9.9.0'; config['bme_always_on']=True
config.setdefault('manual_profile','auto')
config.setdefault('screensaver',{}).setdefault('delay_seconds',120)
defs={
 'performance':{'governor':'performance','brightness':100,'metric_seconds':4,'audio':80,'screensaver_seconds':180,'animations':True,'wifi':True,'vnc':True,'camera':True},
 'maintenance':{'governor':'ondemand','brightness':65,'metric_seconds':7,'audio':65,'screensaver_seconds':120,'animations':False,'wifi':True,'vnc':True,'camera':True},
 'saver':{'governor':'powersave','brightness':25,'metric_seconds':12,'audio':35,'screensaver_seconds':45,'animations':False,'wifi':True,'vnc':False,'camera':False},
}
profiles=config.setdefault('profiles',{})
for name,values in defs.items():
    current=profiles.setdefault(name,{})
    for key,value in values.items(): current.setdefault(key,value)
config_path.write_text(json.dumps(config,ensure_ascii=False,indent=2),encoding='utf-8')
PY

python3 -m py_compile "$INSTALL_ROOT/nspire98.py" || die "Laajennetun hallintapalvelun Python-tarkistus epäonnistui"

log "Asennetaan sovellushaku, suosikit, viimeksi käytetyt, profiilieditori ja insinöörityökalut"

cat > "$ASSET_ROOT/nspire99-extra.css" <<'CSS'
#n99-launch{position:fixed;z-index:2147483045;left:50px;top:6px;height:31px;min-width:40px;border-radius:9px;border:1px solid #31445b;background:rgba(11,17,25,.94);color:#fff;font-size:18px}
#n99-overlay{position:fixed;z-index:2147483600;inset:39px 5px 5px;background:#080d14f7;color:#f3f7fb;border:1px solid #31445b;border-radius:14px;overflow:auto;padding:10px;font-family:system-ui;box-shadow:0 10px 35px #000d}
#n99-overlay.n99-hidden{display:none!important}.n99-head{position:sticky;top:-10px;background:#080d14;z-index:3;display:flex;gap:7px;align-items:center;padding:8px 0}.n99-head h2{font-size:18px;margin:0;flex:1}.n99-close,.n99-btn{border:1px solid #31445b;background:#15202d;color:#f3f7fb;border-radius:9px;min-height:38px;padding:5px 9px;font-weight:600}
.n99-search{width:100%;min-height:41px;background:#101923;color:#fff;border:1px solid #3b526b;border-radius:10px;padding:7px 10px;font-size:16px;box-sizing:border-box}.n99-results{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:7px;margin-top:8px}.n99-result{min-height:62px;border:1px solid #31445b;background:#15202d;color:#fff;border-radius:10px;padding:7px;text-align:left;overflow:hidden}.n99-result b{display:block;font-size:13px;white-space:nowrap;text-overflow:ellipsis;overflow:hidden}.n99-star{float:right;color:#ffd166;font-size:18px}
.n99-tabs{display:flex;gap:6px;overflow:auto;margin:7px 0}.n99-tabs button{white-space:nowrap}.n99-section{background:#111a25;border:1px solid #31445b;border-radius:11px;padding:9px;margin:8px 0}.n99-section h3{margin:0 0 7px;color:#65bfff}.n99-fields{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px}.n99-fields label{display:grid;gap:3px;color:#b8c6d2;font-size:12px}.n99-fields input,.n99-fields select{min-height:38px;border:1px solid #3b526b;background:#0b1119;color:#fff;border-radius:8px;padding:5px;min-width:0}.n99-output{white-space:pre-wrap;background:#05080d;border-radius:9px;padding:9px;font:13px/1.4 ui-monospace,monospace;min-height:45px}.n99-table{width:100%;border-collapse:collapse;font-size:12px}.n99-table td,.n99-table th{border-bottom:1px solid #26384b;padding:5px;text-align:left}.n99-good{color:#78d99a}.n99-warn{color:#ffd166}
@media(max-width:700px){.n99-results{grid-template-columns:repeat(2,minmax(0,1fr))}.n99-fields{grid-template-columns:1fr}}
CSS

cat > "$ASSET_ROOT/nspire99-extra.js" <<'JS'
(()=>{'use strict';
const API='http://127.0.0.1:8770/api';
const S={apps:[],favorites:new Set(JSON.parse(localStorage.getItem('n99-favorites')||'[]')),recent:JSON.parse(localStorage.getItem('n99-recent')||'[]'),profile:'maintenance',status:null,tool:'units'};
const $=(s,r=document)=>r.querySelector(s), $$=(s,r=document)=>[...r.querySelectorAll(s)];
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function api(body){const r=await fetch(API+'/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const x=await r.json();if(!x.ok)throw Error(x.error||'Virhe');return x.result}
async function status(){const r=await fetch(API+'/status');S.status=await r.json();return S.status}
function tileName(el){return (el.dataset.title||el.dataset.name||$('.app-name,.tile-title,.label',el)?.textContent||el.textContent||'').trim().replace(/\s+/g,' ')}
function isFolder(el){return el.matches('[data-folder],.folder-tile,.app-folder,[data-type="folder"]')||/kansio/i.test(el.className)}
function registry(){const grid=$('.app-grid,.home-grid');if(!grid)return[];const seen=new Set();S.apps=$$('.app-tile,.tile,[data-app]',grid).filter(x=>x.id!=='n98-settings-tile'&&x.id!=='n99-search-tile'&&x.id!=='n99-tools-tile').map(el=>({name:tileName(el),el,folder:isFolder(el)})).filter(a=>a.name&&!seen.has(a.name.toLocaleLowerCase('fi'))&&seen.add(a.name.toLocaleLowerCase('fi'))).sort((a,b)=>a.name.localeCompare(b.name,'fi'));return S.apps}
function remember(name){S.recent=[name,...S.recent.filter(x=>x!==name)].slice(0,12);localStorage.setItem('n99-recent',JSON.stringify(S.recent))}
function toggleFav(name){S.favorites.has(name)?S.favorites.delete(name):S.favorites.add(name);localStorage.setItem('n99-favorites',JSON.stringify([...S.favorites]));sortHome();renderSearch($('#n99-query')?.value||'')}
function sortHome(){const grid=$('.app-grid,.home-grid');if(!grid)return;const children=[...grid.children].filter(x=>!x.hidden);children.sort((a,b)=>{const fa=isFolder(a)?0:S.favorites.has(tileName(a))?1:2,fb=isFolder(b)?0:S.favorites.has(tileName(b))?1:2;return fa-fb||tileName(a).localeCompare(tileName(b),'fi')});children.forEach(x=>grid.appendChild(x))}
function addTile(id,label,icon,handler){const grid=$('.app-grid,.home-grid');if(!grid||document.getElementById(id))return;const proto=$('.app-tile,.tile',grid),t=proto?proto.cloneNode(false):document.createElement('button');t.id=id;t.classList.add('app-tile');t.dataset.folder='n99';t.innerHTML=`<span style="font-size:25px">${icon}</span><span class="app-name">${label}</span>`;t.onclick=e=>{e.preventDefault();handler()};grid.insertBefore(t,grid.firstChild)}
function ensure(){let launch=$('#n99-launch');if(!launch){launch=document.createElement('button');launch.id='n99-launch';launch.textContent='⌕';launch.title='Haku, suosikit ja työkalut';launch.onclick=()=>openSearch();document.body.appendChild(launch)}let overlay=$('#n99-overlay');if(!overlay){overlay=document.createElement('div');overlay.id='n99-overlay';overlay.className='n99-hidden';document.body.appendChild(overlay);overlay.addEventListener('click',click);overlay.addEventListener('input',input)}addTile('n99-search-tile','Haku ja suosikit','⌕',openSearch);addTile('n99-tools-tile','Insinöörityökalut','⚙',()=>openTools('units'));registry();sortHome()}
function openSearch(){ensure();$('#n99-overlay').classList.remove('n99-hidden');$('#n99-overlay').innerHTML=`<div class="n99-head"><h2>Sovellukset</h2><button class="n99-btn" data-page="profiles">Profiilit</button><button class="n99-btn" data-page="tools">Työkalut</button><button class="n99-close" data-close>×</button></div><input id="n99-query" class="n99-search" placeholder="Hae sovellusta…" autocomplete="off"><div class="n99-tabs"><button class="n99-btn" data-filter="all">Kaikki</button><button class="n99-btn" data-filter="favorites">Suosikit</button><button class="n99-btn" data-filter="recent">Viimeksi käytetyt</button></div><div id="n99-results" class="n99-results"></div>`;renderSearch('');setTimeout(()=>$('#n99-query')?.focus(),50)}
function renderSearch(q='',filter='all'){registry();q=q.trim().toLocaleLowerCase('fi');let apps=S.apps;if(filter==='favorites')apps=apps.filter(a=>S.favorites.has(a.name));if(filter==='recent')apps=S.recent.map(n=>apps.find(a=>a.name===n)).filter(Boolean);if(q)apps=apps.filter(a=>a.name.toLocaleLowerCase('fi').includes(q));const box=$('#n99-results');if(!box)return;box.innerHTML=apps.map((a,i)=>`<button class="n99-result" data-open="${i}" data-name="${esc(a.name)}"><span class="n99-star" data-star="${esc(a.name)}">${S.favorites.has(a.name)?'★':'☆'}</span><b>${esc(a.name)}</b><small>${a.folder?'Kansio':'Sovellus'}</small></button>`).join('')||'<div class="n99-section">Ei tuloksia</div>';box._apps=apps}
function openApp(index){const apps=$('#n99-results')?._apps||[];const app=apps[index];if(!app)return;remember(app.name);localStorage.setItem('n99-last-app',app.name);$('#n99-overlay').classList.add('n99-hidden');app.el.click()}
function openProfiles(){status().then(()=>{S.profile=S.status.profile&&S.status.profile!=='unknown'?S.status.profile:'maintenance';renderProfiles()}).catch(e=>alert(e.message));$('#n99-overlay').classList.remove('n99-hidden')}
function profileData(){return S.status?.config?.profiles?.[S.profile]||{}}
function renderProfiles(){const p=profileData();$('#n99-overlay').innerHTML=`<div class="n99-head"><h2>Virtaprofiilien lisäasetukset</h2><button class="n99-close" data-close>×</button></div><div class="n99-tabs">${['performance','maintenance','saver'].map(x=>`<button class="n99-btn" data-profile-edit="${x}">${x==='performance'?'Teho':x==='maintenance'?'Ylläpito':'Säästö'}</button>`).join('')}</div><div class="n99-section"><h3>${S.profile}</h3><div class="n99-fields"><label>CPU governor<select id="p-governor"><option>performance</option><option>ondemand</option><option>powersave</option><option>schedutil</option></select></label><label>Kirkkaus %<input id="p-brightness" type="number" min="5" max="100" value="${p.brightness??60}"></label><label>Ääni %<input id="p-audio" type="number" min="0" max="100" value="${p.audio??60}"></label><label>Tilapalkin päivitys s<input id="p-metric" type="number" min="4" max="60" value="${p.metric_seconds??7}"></label><label>Näytönsäästäjä s<input id="p-saver" type="number" min="20" max="7200" value="${p.screensaver_seconds??120}"></label><label><span>Wi-Fi</span><input id="p-wifi" type="checkbox" ${p.wifi!==false?'checked':''}></label><label><span>VNC</span><input id="p-vnc" type="checkbox" ${p.vnc!==false?'checked':''}></label><label><span>Kamera</span><input id="p-camera" type="checkbox" ${p.camera!==false?'checked':''}></label><label><span>Animaatiot</span><input id="p-animations" type="checkbox" ${p.animations?'checked':''}></label></div><button class="n99-btn" data-save-profile style="width:100%;margin-top:10px">Tallenna profiili</button><p class="n99-good">BME680 pysyy aina käytössä profiilista riippumatta.</p></div>`;$('#p-governor').value=p.governor||'ondemand'}
async function saveProfile(){const settings={governor:$('#p-governor').value,brightness:+$('#p-brightness').value,audio:+$('#p-audio').value,metric_seconds:+$('#p-metric').value,screensaver_seconds:+$('#p-saver').value,wifi:$('#p-wifi').checked,vnc:$('#p-vnc').checked,camera:$('#p-camera').checked,animations:$('#p-animations').checked};await api({action:'save_profile',profile:S.profile,settings});await status();renderProfiles();alert('Profiili tallennettu')}
const units={length:{mm:0.001,cm:0.01,m:1,km:1000,in:0.0254,ft:0.3048},pressure:{Pa:1,kPa:1000,MPa:1e6,bar:1e5,psi:6894.757},torque:{Nm:1,Nmm:0.001,kNm:1000,lbf_ft:1.35581795},power:{W:1,kW:1000,hp:745.699872},mass:{g:0.001,kg:1,t:1000,lb:0.45359237}};
const materials=[['S235 teräs',7850,210,235],['S355 teräs',7850,210,355],['42CrMo4 QT',7850,210,650],['EN AW-6082 T6',2700,70,250],['EN AW-7075 T6',2810,72,500],['AISI 304',8000,193,215],['AISI 316',8000,193,205],['POM',1410,2.8,65],['PA6',1130,2.5,55]];
const threads={M2:.4,M2_5:.45,M3:.5,M4:.7,M5:.8,M6:1,M8:1.25,M10:1.5,M12:1.75,M14:2,M16:2,M18:2.5,M20:2.5,M22:2.5,M24:3,M27:3,M30:3.5};
const fits={H7_h6:[0,21],H7_g6:[5,34],H7_f7:[13,54],H7_p6:[-42,-10]};
function openTools(tool='units'){S.tool=tool;ensure();$('#n99-overlay').classList.remove('n99-hidden');renderTools()}
function tabs(){return ['units','materials','fits','threads','bearings','strength'].map(x=>`<button class="n99-btn" data-tool="${x}">${({units:'Muunnin',materials:'Materiaalit',fits:'Sovitteet',threads:'Kierteet',bearings:'Laakerit',strength:'Lujuus'})[x]}</button>`).join('')}
function renderTools(){let body='';if(S.tool==='units')body=`<div class="n99-section"><h3>Yksikkömuunnin</h3><div class="n99-fields"><label>Ryhmä<select id="u-cat">${Object.keys(units).map(x=>`<option>${x}</option>`).join('')}<option>temperature</option></select></label><label>Arvo<input id="u-val" type="number" value="1" step="any"></label><label>Mistä<select id="u-from"></select></label><label>Mihin<select id="u-to"></select></label></div><button class="n99-btn" data-calc="units">Laske</button><div id="tool-out" class="n99-output"></div></div>`;
if(S.tool==='materials')body=`<div class="n99-section"><h3>Materiaalitaulukko</h3><table class="n99-table"><tr><th>Materiaali</th><th>ρ kg/m³</th><th>E GPa</th><th>Rp0.2 MPa</th></tr>${materials.map(x=>`<tr><td>${x[0]}</td><td>${x[1]}</td><td>${x[2]}</td><td>${x[3]}</td></tr>`).join('')}</table></div>`;
if(S.tool==='fits')body=`<div class="n99-section"><h3>Yleiset sovitteet</h3><div class="n99-fields"><label>Nimellismitta mm<input id="f-d" type="number" value="25" min="1" step="any"></label><label>Sovite<select id="f-fit">${Object.keys(fits).map(x=>`<option value="${x}">${x.replace('_','/')}</option>`).join('')}</select></label></div><button class="n99-btn" data-calc="fits">Arvioi välys</button><div id="tool-out" class="n99-output"></div><small class="n99-warn">Nopea työpaja-arvio. Lopulliset rajamitat tarkistetaan ISO 286 -taulukosta.</small></div>`;
if(S.tool==='threads')body=`<div class="n99-section"><h3>Metriset kierteet</h3><div class="n99-fields"><label>Kierre<select id="t-size">${Object.entries(threads).map(([x,p])=>`<option value="${x}">${x.replace('_','.') } × ${p}</option>`).join('')}</select></label></div><button class="n99-btn" data-calc="threads">Näytä</button><div id="tool-out" class="n99-output"></div></div>`;
if(S.tool==='bearings')body=`<div class="n99-section"><h3>Laakerin L10-kestoikä</h3><div class="n99-fields"><label>Dynaaminen kantavuus C, N<input id="b-c" type="number" value="25000"></label><label>Ekvivalenttikuorma P, N<input id="b-p" type="number" value="3000"></label><label>Pyörimisnopeus rpm<input id="b-rpm" type="number" value="1500"></label><label>Tyyppi<select id="b-type"><option value="3">Kuulalaakeri</option><option value="3.333333333">Rullalaakeri</option></select></label></div><button class="n99-btn" data-calc="bearings">Laske</button><div id="tool-out" class="n99-output"></div></div>`;
if(S.tool==='strength')body=`<div class="n99-section"><h3>Lujuuslaskut</h3><div class="n99-fields"><label>Lasku<select id="s-type"><option value="axial">Aksiaalijännitys F/A</option><option value="bend">Taivutus σ=M/W</option><option value="torsion">Vääntö τ=16T/(πd³)</option><option value="power">Momentti tehosta</option></select></label><label>Arvo 1<input id="s-a" type="number" value="10000" step="any"></label><label>Arvo 2<input id="s-b" type="number" value="100" step="any"></label><label>Arvo 3<input id="s-c" type="number" value="50" step="any"></label></div><button class="n99-btn" data-calc="strength">Laske</button><button class="n99-btn" data-copy> Kopioi tulos</button><div id="tool-out" class="n99-output"></div></div>`;
$('#n99-overlay').innerHTML=`<div class="n99-head"><h2>Insinöörityökalut</h2><button class="n99-btn" data-page="search">Sovellukset</button><button class="n99-close" data-close>×</button></div><div class="n99-tabs">${tabs()}</div>${body}`;if(S.tool==='units')fillUnits()}
function fillUnits(){const cat=$('#u-cat').value,keys=cat==='temperature'?['C','F','K']:Object.keys(units[cat]);$('#u-from').innerHTML=keys.map(x=>`<option>${x}</option>`).join('');$('#u-to').innerHTML=keys.map(x=>`<option>${x}</option>`).join('');$('#u-to').selectedIndex=Math.min(1,keys.length-1)}
function output(text){const o=$('#tool-out');if(o)o.textContent=text}
function calculate(kind){if(kind==='units'){const cat=$('#u-cat').value,v=+$('#u-val').value,a=$('#u-from').value,b=$('#u-to').value;let r;if(cat==='temperature'){let c=a==='C'?v:a==='F'?(v-32)*5/9:v-273.15;r=b==='C'?c:b==='F'?c*9/5+32:c+273.15}else r=v*units[cat][a]/units[cat][b];output(`${v} ${a} = ${Number(r.toPrecision(9))} ${b}`)}
if(kind==='fits'){const d=+$('#f-d').value,[min,max]=fits[$('#f-fit').value],scale=Math.max(.55,Math.pow(d/25,.34));output(`Nimellismitta: ${d.toFixed(3)} mm\nArvioitu välys/interferenssi: ${(min*scale/1000).toFixed(3)} … ${(max*scale/1000).toFixed(3)} mm\nPositiivinen = välys, negatiivinen = ahdistus.`)}
if(kind==='threads'){const key=$('#t-size').value,p=threads[key],d=+key.slice(1).replace('_','.');output(`${key.replace('_','.')} × ${p}\nSuositeltu kierrepora ≈ ${(d-p).toFixed(2)} mm\nNousu p = ${p} mm`)}
if(kind==='bearings'){const C=+$('#b-c').value,P=+$('#b-p').value,rpm=+$('#b-rpm').value,p=+$('#b-type').value,L10=Math.pow(C/P,p),hours=L10*1e6/(60*rpm);output(`L10 = ${L10.toFixed(2)} miljoonaa kierrosta\nL10h = ${hours.toFixed(0)} h\nKaava: L10=(C/P)^p`)}
if(kind==='strength'){const type=$('#s-type').value,a=+$('#s-a').value,b=+$('#s-b').value,c=+$('#s-c').value;let t='';if(type==='axial')t=`σ = F/A = ${(a/b).toFixed(3)} N/mm²`;if(type==='bend')t=`σ = M/W = ${(a/b).toFixed(3)} N/mm²`;if(type==='torsion')t=`τ = 16T/(πd³) = ${(16*a*1000/(Math.PI*Math.pow(b,3))).toFixed(3)} N/mm²`;if(type==='power')t=`T = 9550·P/n = ${(9550*a/b).toFixed(3)} Nm`;output(t)}}
function click(e){const b=e.target.closest('button');if(!b)return;if(b.dataset.close!==undefined)$('#n99-overlay').classList.add('n99-hidden');if(b.dataset.page==='profiles')openProfiles();if(b.dataset.page==='tools')openTools();if(b.dataset.page==='search')openSearch();if(b.dataset.filter)renderSearch($('#n99-query')?.value||'',b.dataset.filter);if(b.dataset.open!==undefined&&!e.target.dataset.star)openApp(+b.dataset.open);if(e.target.dataset.star){e.stopPropagation();toggleFav(e.target.dataset.star)}if(b.dataset.profileEdit){S.profile=b.dataset.profileEdit;renderProfiles()}if(b.dataset.saveProfile!==undefined)saveProfile().catch(x=>alert(x.message));if(b.dataset.tool)openTools(b.dataset.tool);if(b.dataset.calc)calculate(b.dataset.calc);if(b.dataset.copy!==undefined)navigator.clipboard?.writeText($('#tool-out')?.textContent||'')}
function input(e){if(e.target.id==='n99-query')renderSearch(e.target.value);if(e.target.id==='u-cat')fillUnits()}
function track(e){const tile=e.target.closest('.app-tile,.tile,[data-app]');if(!tile||tile.id?.startsWith('n9'))return;const name=tileName(tile);if(name){remember(name);if(isFolder(tile))localStorage.setItem('n99-last-folder',name)}}
function enhancePanel(){const p=$('#n98-panel');if(!p||p.classList.contains('n98-hidden')||$('[data-n99-profiles]',p))return;const actions=$('.n98-actions',p);if(actions){const b=document.createElement('button');b.dataset.n99Profiles='';b.textContent='Profiilien lisäsäädöt';b.onclick=openProfiles;actions.appendChild(b)}}
function applyCameraPolicy(){const enabled=S.status?.config?.profiles?.[S.status?.profile]?.camera!==false;$$('.app-tile,.tile,[data-app]').forEach(t=>{if(/kamera|valvonta|live/i.test(tileName(t)))t.style.opacity=enabled?'':'0.45'})}
function boot(){ensure();document.addEventListener('click',track,true);new MutationObserver(()=>{ensure();enhancePanel()}).observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class']});setInterval(()=>status().then(()=>{applyCameraPolicy();enhancePanel()}).catch(()=>{}),15000);status().then(applyCameraPolicy).catch(()=>{})}
document.readyState==='loading'?document.addEventListener('DOMContentLoaded',boot,{once:true}):boot();
})();
JS

if command -v node >/dev/null 2>&1; then
  node --check "$ASSET_ROOT/nspire99-extra.js" || die "V9.9-lisäosan JavaScript-tarkistus epäonnistui"
fi

log "Korjataan V9.8-pohjan ajastuksen alustus ja himmennyksen palautus"
python3 - "$ASSET_ROOT/nspire98.js" "$INDEX" <<'PY'
from pathlib import Path
import sys,re
js=Path(sys.argv[1]); index=Path(sys.argv[2])
text=js.read_text(encoding='utf-8')
text=text.replace("const state={status:null,timer:null,idle:null,dim:null,saver:false,lastRepair:0,lastFolder:null};","const state={status:null,timer:null,idle:null,dim:null,saver:false,lastRepair:0,lastFolder:null,preDim:null};")
text=text.replace("state.dim=setTimeout(()=>api('/action',{action:'brightness',value:Math.max(8,(state.status?.brightness||60)*.45|0)}).catch(()=>{}),(delay-dim)*1000)","state.dim=setTimeout(()=>{state.preDim=state.status?.brightness||60;api('/action',{action:'brightness',value:Math.max(8,state.preDim*.45|0)}).catch(()=>{})},(delay-dim)*1000)")
text=text.replace("function hideSaver(){if(!state.saver)return;state.saver=false;$('#n98-saver').classList.add('n98-hidden');resetIdle()}","function restoreDim(){if(state.preDim!=null){api('/action',{action:'brightness',value:state.preDim}).catch(()=>{});state.preDim=null}}\nfunction hideSaver(){restoreDim();if(!state.saver)return;state.saver=false;$('#n98-saver').classList.add('n98-hidden');resetIdle()}")
text=text.replace("refresh();resetIdle();['pointerdown'","refresh();setTimeout(resetIdle,1500);['pointerdown'")
js.write_text(text,encoding='utf-8')
html=index.read_text(encoding='utf-8',errors='replace')
html=html.replace('href="nspire98/nspire98.css?v=9.8.0"','href="/nspire98/nspire98.css?v=9.9.0"').replace('src="nspire98/nspire98.js?v=9.8.0"','src="/nspire98/nspire98.js?v=9.9.0"')
css='<link id="nspire99-css" rel="stylesheet" href="/nspire98/nspire99-extra.css?v=9.9.0">'
script='<script id="nspire99-js" defer src="/nspire98/nspire99-extra.js?v=9.9.0"></script>'
if 'id="nspire99-css"' not in html:
    html=html.replace('</head>',css+'\n'+script+'\n</head>')
else:
    html=re.sub(r'<link id="nspire99-css"[^>]*>',css,html)
    html=re.sub(r'<script id="nspire99-js"[^>]*></script>',script,html)
index.write_text(html,encoding='utf-8')
PY

cat > /etc/nspire-v98/CHANGELOG-V9.9.0.txt <<'TXT'
NSPIRE V9.9.0 COMPLETE SUITE

Kaikki V9.8.0-vakaus- ja Daily Driver -ominaisuudet sekä:
- sovellushaku
- suosikit
- viimeksi käytetyt sovellukset
- suosikkien järjestäminen kansioiden jälkeen
- virtaprofiilien selkeä lisäeditori
- kirkkaus, CPU governor, ääni, tilapäivitysväli, näytönsäästäjän viive, Wi-Fi, VNC, kamera ja animaatiot profiilikohtaisesti
- BME680 aina toiminnassa
- näytönsäästäjäajastimen varma alustus
- himmennyksen palautus käyttäjän palatessa
- insinöörityökalut: yksikkömuunnin, materiaalitaulukko, sovitearviot, kierrepora, laakerin L10-kestoikä ja lujuuden peruslaskut
TXT

# Päivitä käyttöliittymän versionäyttöjen yleiset V9.8-merkkijonot vain omista lisäosista.
sed -i 's/NSPIRE V9\.8/NSPIRE V9.9/g' "$ASSET_ROOT/nspire98.js" "$ASSET_ROOT/nspire99-extra.js" 2>/dev/null || true

systemctl daemon-reload
systemctl restart nspire-v98-api.service
sleep 2
curl -fsS --max-time 5 http://127.0.0.1:8770/api/status >/tmp/nspire-v99-status.json
python3 - <<'PY'
import json
x=json.load(open('/tmp/nspire-v99-status.json'))
assert x.get('version')=='9.9.0',x
assert x.get('config',{}).get('bme_always_on') is True,x
for p in ('performance','maintenance','saver'):
    cfg=x['config']['profiles'][p]
    for key in ('brightness','governor','audio','screensaver_seconds','wifi','vnc','camera'):
        assert key in cfg,(p,key,cfg)
print('V9.9 API ja profiilit OK')
PY

grep -q 'id="nspire99-js"' "$INDEX"
[[ -s "$ASSET_ROOT/nspire99-extra.js" && -s "$ASSET_ROOT/nspire99-extra.css" ]]
python3 "$INSTALL_ROOT/nspire98.py" restart >/dev/null 2>&1 || true

log "NSPIRE V${VERSION} COMPLETE SUITE asennettu"
echo "Varmuuskopio ennen V9.9-laajennusta: $EXTRA_BACKUP"
echo "Anna käyttöliittymälle 15–25 sekuntia käynnistyä."
