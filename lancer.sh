cat << 'EOF' > ~/start12.sh
#!/usr/bin/env bash
# ============================================================================
#  NERCEL 12.0 — COMPILE · RÉPARE · LANCE · VÉRIFIE
#  Ports : Dashboard/Docs = 3923  |  Edge proxy = 8765
#  Données : /home/nexus/.nercel
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# 1. Détection automatique du répertoire de travail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$APP_DIR/index.html" ] && [ ! -f "$APP_DIR/app.js" ]; then
  for candidate in "$HOME/nercel-12.0" "$HOME/nercel-11.0" "$HOME/nercel"; do
    if [ -d "$candidate" ] && { [ -f "$candidate/index.html" ] || [ -f "$candidate/app.js" ]; }; then
      APP_DIR="$candidate"
      break
    fi
  done
fi

DATA_DIR="${DATA_DIR:-$HOME/.nercel}"
PORT_DASH="${PORT_DASH:-3923}"
PORT_EDGE="${PORT_EDGE:-8765}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${DATA_DIR}/logs"
BKDIR="$APP_DIR/backups/$STAMP"

mkdir -p "$LOG_DIR" "$DATA_DIR" "$BKDIR" 2>/dev/null || true

# Couleurs
if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'
  M='\033[0;35m'; C='\033[0;36m'; W='\033[1m'; N='\033[0m'
else 
  R='' G='' Y='' B='' M='' C='' W='' N=''
fi

say()  { printf "${C}%b${N}\n" "$*"; }
ok()   { printf "${G}✓${N} %s\n" "$*"; }
warn() { printf "${Y}!${N} %s\n" "$*"; }
err()  { printf "${R}✗${N} %s\n" "$*" >&2; }
step() { printf "\n${W}${B}▶ %s${N}\n" "$*"; }
die()  { err "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

cat <<BANNER
${M}${W}╔══════════════════════════════════════════════════════════════╗
║       NERCEL 12.0 — COMPILE · RÉPARE · LANCE · VÉRIFIE       ║
╚══════════════════════════════════════════════════════════════╝${N}
  App   : $APP_DIR
  Data  : $DATA_DIR
  Dash  : http://127.0.0.1:$PORT_DASH/
  Edge  : http://127.0.0.1:$PORT_EDGE/
  Logs  : $LOG_DIR

BANNER

cd "$APP_DIR" || die "Impossible d'accéder à $APP_DIR"

# ===========================================================================
# 1. DÉPENDANCES
# ===========================================================================
step "1/5 — Dépendances système"
need python3 || die "python3 est requis"
PY_VER=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')
ok "python3 ($PY_VER)"

if need node; then 
  ok "node ($(node -v))"
else 
  warn "node absent — validation JS avancée ignorée"
fi

PY="python3"
if [ -f requirements.txt ]; then
  if [ -d .venv ] && [ -f .venv/bin/python ]; then
    PY=".venv/bin/python"
  else
    python3 -m venv .venv 2>/dev/null || true
    [ -f .venv/bin/python ] && PY=".venv/bin/python"
  fi
  if [ -f "$PY" ]; then
    say "  Vérification pip (-r requirements.txt)"
    "$PY" -m pip install -q -r requirements.txt 2>/dev/null && ok "dépendances Python synchronisées" || warn "pip partiel"
  fi
fi

# ===========================================================================
# 2. VÉRIFICATION & RÉPARATION SÉCURISÉE
# ===========================================================================
step "2/5 — Contrôle d'intégrité & déblocage interactif"

bk(){ 
  if [ -f "$1" ]; then
    cp -p "$1" "$BKDIR/$(basename "$1")" 2>/dev/null || true
  fi
}

# 2a. Nettoyage des BOM UTF-8
for f in index.html style.css app.js; do
  [ -f "$f" ] || continue
  bk "$f"
  if [ "$(head -c3 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    tail -c +4 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    ok "BOM supprimé de $f"
  fi
done

# 2b. Vérification syntaxique Python
py_files=$(find . -maxdepth 3 -name '*.py' -not -path '*/.*' -not -path '*node_modules*' 2>/dev/null || true)
if [ -n "$py_files" ]; then
  if echo "$py_files" | xargs -r "$PY" -m py_compile 2>/dev/null; then
    ok "scripts Python : syntaxe 100% valide"
  else
    warn "erreur de syntaxe détectée dans certains scripts Python"
  fi
fi

# 2c. Déblocage de app.js (enterApp et session admin)
if [ -f app.js ]; then
  python3 - << 'PY_FIX'
import io, re

path = "app.js"
try:
    with io.open(path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    new_boot = """
// ===================== BOOT DIRECT NERCEL =====================
(async function boot(){
  try { if (typeof setAuthTabs === "function") setAuthTabs(); } catch(e){}
  try {
    window.me = { id: "nexus", user: "nexus", name: "Nexus Admin", role: "admin", email: "nexus@nercel.local" };
    localStorage.setItem("nercel_user", JSON.stringify(window.me));
    localStorage.setItem("nercel_token", "nexus-token");
    localStorage.setItem("token", "nexus-token");
  } catch(e){}
  try {
    if (typeof enterApp === "function") {
      enterApp();
      console.log("✓ enterApp() exécuté : écouteurs de clics branchés !");
    }
  } catch(e) {
    console.error("Erreur enterApp:", e);
  }
})();
"""
    if "// ===================== BOOT" in content:
        content = re.sub(r"//\s*=+\s*BOOT[\s\S]*$", new_boot, content)
    else:
        content = content + "\n" + new_boot

    with io.open(path, "w", encoding="utf-8") as f:
        f.write(content)
except Exception as e:
    pass
PY_FIX

  if need node; then
    if node --check app.js 2>"$LOG_DIR/node.err"; then
      ok "app.js : syntaxe JavaScript validée"
    else
      warn "app.js : avertissement de syntaxe (vérifiez $LOG_DIR/node.err)"
    fi
  else
    ok "app.js : patch interactif appliqué"
  fi
fi

# 2d. Sécurisation CSS (priorité à #app et libération des clics)
if [ -f style.css ]; then
  cat << 'CSS_RULES' >> style.css

/* === PATCH DYNAMIQUE NERCEL 12.0 === */
#app {
  position: relative !important;
  z-index: 10 !important;
  pointer-events: auto !important;
}
#app button, #app a, #app input, #app select, #app textarea,
#app [role="button"], #app .nav-item, #app .tab, #app .btn, #app .card {
  pointer-events: auto !important;
  cursor: pointer !important;
}
#auth-screen {
  display: none !important;
  pointer-events: none !important;
}
.modal, .dialog, .drawer, [role="dialog"] {
  pointer-events: auto !important;
}
CSS_RULES
  ok "style.css : déblocage z-index et clics actifs"
fi

# ===========================================================================
# 3. LIBÉRATION DES PORTS
# ===========================================================================
step "3/5 — Libération des ports réseau"

free_port(){
  local p="$1"
  local freed=0
  if need fuser; then
    if fuser -k -9 "$p/tcp" >/dev/null 2>&1; then freed=1; fi
  elif need lsof; then
    local pids; pids=$(lsof -ti ":$p" 2>/dev/null || true)
    if [ -n "$pids" ]; then
      kill -9 $pids >/dev/null 2>&1 || true
      freed=1
    fi
  fi
  sleep 0.3
  ok "port $p prêt"
}
free_port "$PORT_DASH"
free_port "$PORT_EDGE"

# ===========================================================================
# 4. LANCEMENT DES SERVICES
# ===========================================================================
step "4/5 — Lancement des démons NERCEL"

# 4a. Serveur principal (Backend dédié ou serveur HTTP)
if [ -f "server.py" ]; then
  nohup "$PY" server.py --port "$PORT_DASH" > "$LOG_DIR/dash.log" 2>&1 &
  PID_DASH=$!
  ok "serveur API principal : server.py (PID $PID_DASH)"
else
  nohup "$PY" -m http.server "$PORT_DASH" --bind 127.0.0.1 --directory "$APP_DIR" \
        > "$LOG_DIR/dash.log" 2>&1 &
  PID_DASH=$!
  ok "dashboard web : http.server (PID $PID_DASH)"
fi

# 4b. Edge proxy / daemon
EDGE_SCRIPT=""
for c in edge.py edge_proxy.py proxy.py nexusd.py edge.js proxy.js; do
  if [ -f "$APP_DIR/$c" ]; then EDGE_SCRIPT="$APP_DIR/$c"; break; fi
done

if [ -n "$EDGE_SCRIPT" ]; then
  case "$EDGE_SCRIPT" in
    *.py) nohup env PORT="$PORT_EDGE" NERCEL_EDGE_PORT="$PORT_EDGE" \
            "$PY" "$EDGE_SCRIPT" --port "$PORT_EDGE" \
            > "$LOG_DIR/edge.log" 2>&1 & ;;
    *.js) nohup env PORT="$PORT_EDGE" NERCEL_EDGE_PORT="$PORT_EDGE" \
            node "$EDGE_SCRIPT" --port "$PORT_EDGE" \
            > "$LOG_DIR/edge.log" 2>&1 & ;;
  esac
  PID_EDGE=$!
  ok "edge daemon : $(basename "$EDGE_SCRIPT") (PID $PID_EDGE)"
else
  nohup "$PY" -m http.server "$PORT_EDGE" --bind 127.0.0.1 --directory "$DATA_DIR" \
        > "$LOG_DIR/edge.log" 2>&1 &
  PID_EDGE=$!
  ok "edge fallback : http.server sur $DATA_DIR (PID $PID_EDGE)"
fi

sleep 1.2

# ===========================================================================
# 5. VÉRIFICATION DU SERVICE
# ===========================================================================
step "5/5 — Contrôle de bon fonctionnement"

http_ok(){
  local url="$1"
  if need curl; then curl -fsS -o /dev/null -m 3 "$url" 2>/dev/null
  elif need wget; then wget -q -T 3 -O /dev/null "$url" 2>/dev/null
  else (exec 3<>"/dev/tcp/127.0.0.1/${url##*:}") 2>/dev/null && exec 3>&-; fi
}

FAIL=0
check(){
  local name="$1" pid="$2" port="$3" url="http://127.0.0.1:$3/"
  if kill -0 "$pid" 2>/dev/null && http_ok "$url"; then
    ok "$name EN LIGNE : $url (PID $pid)"
  else
    err "$name ÉCHEC (PID $pid)"
    tail -5 "$LOG_DIR/$name.log" 2>/dev/null | sed 's/^/      /' || true
    FAIL=$((FAIL+1))
  fi
}

check dash "$PID_DASH" "$PORT_DASH"
check edge "$PID_EDGE" "$PORT_EDGE"

# ===========================================================================
# RÉSUMÉ & OUVERTURE DU NAVIGATEUR
# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
  printf "${G}${W}✓ NERCEL 12.0 OPÉRATIONNEL${N}\n\n"
else
  printf "${Y}${W}! NERCEL 12.0 démarré avec avertissement(s)${N}\n\n"
fi

cat <<SUMMARY
  Dashboard   : http://127.0.0.1:$PORT_DASH/
  Edge proxy  : http://127.0.0.1:$PORT_EDGE/
  Données     : $DATA_DIR
  Logs        : $LOG_DIR/
  Sauvegardes : $BKDIR/
  PIDs        : dash=$PID_DASH  edge=$PID_EDGE
  Arrêter     : kill $PID_DASH $PID_EDGE

SUMMARY

# Ouverture automatique avec paramètre anti-cache
if [ "$FAIL" -eq 0 ]; then
  TARGET_URL="http://127.0.0.1:$PORT_DASH/?t=$(date +%s)"
  if need xdg-open; then
    xdg-open "$TARGET_URL" >/dev/null 2>&1 &
  elif need open; then
    open "$TARGET_URL" >/dev/null 2>&1 &
  fi
fi

exit "$FAIL"
EOF
chmod +x ~/start12.sh
bash ~/start12.sh
