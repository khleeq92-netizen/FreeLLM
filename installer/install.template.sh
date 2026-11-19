#!/usr/bin/env bash
# FreeLLM Assistant — one-command installer for macOS (also works on Linux).
#
#   curl -fsSL https://raw.githubusercontent.com/khleeq92-netizen/FreeLLM/claude/lucid-sagan-282tpm/install.sh | bash
#
# What it does (everything lives in ~/FreeLLM-Assistant, no sudo, nothing system-wide):
#   1. Uses your Node.js 20-24 if you have it, otherwise downloads Node 22 (checksum-verified).
#   2. Downloads and builds FreeLLMAPI (the free-LLM router) from GitHub.
#   3. Installs the Assistant web app and its file readers (Excel, Word, PDF).
#   4. Creates start/stop scripts and a "FreeLLM Assistant" shortcut on your Desktop (macOS).
#   5. Starts everything and opens http://127.0.0.1:3100 in your browser.
#
# Re-running it is safe: it updates everything and keeps your data, keys and password.
# An earlier "Course AI" install (~/CourseAI) is migrated automatically.
#
# Optional settings (put them before "bash" or export them first):
#   ASSISTANT_HOME=~/FreeLLM-Assistant   install folder
#   APP_PORT=3100                        Assistant port
#   FREELLMAPI_PORT=3001                 FreeLLMAPI router + dashboard port
#   FREELLMAPI_REF=main                  FreeLLMAPI branch or tag to install
#   GEMINI_API_KEY=... GROQ_API_KEY=... CEREBRAS_API_KEY=... OPENROUTER_API_KEY=... MISTRAL_API_KEY=...
#                                        free provider keys to add on first start
#   ASSISTANT_NO_OPEN=1                  do not open the browser
#   ASSISTANT_NO_START=1                 install only, do not start

set -euo pipefail

HOME_DIR="${ASSISTANT_HOME:-$HOME/FreeLLM-Assistant}"
APP_PORT="${APP_PORT:-3100}"
FL_PORT="${FREELLMAPI_PORT:-3001}"
FL_REF="${FREELLMAPI_REF:-main}"
FL_REPO="tashfeenahmed/freellmapi"
NODE_LINE="v22"
OLD_HOME="$HOME/CourseAI"
SHORTCUT="$HOME/Desktop/FreeLLM Assistant.command"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;35m▸ %s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS" in
  Darwin) NODE_OS=darwin ;;
  Linux)  NODE_OS=linux ;;
  *) die "Unsupported system: $OS (this installer supports macOS and Linux)" ;;
esac
case "$ARCH" in
  arm64|aarch64) NODE_ARCH=arm64 ;;
  x86_64|amd64)  NODE_ARCH=x64 ;;
  *) die "Unsupported CPU: $ARCH" ;;
esac

command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"

sha256() {
  if command -v shasum >/dev/null; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

bold ""
bold "🤖 FreeLLM Assistant installer"
info "Install folder: $HOME_DIR"
mkdir -p "$HOME_DIR"/{config,data,logs,run,runtime,app/public}
chmod 700 "$HOME_DIR/config" "$HOME_DIR/data"

# Stop a previous run before replacing files.
if [ -x "$HOME_DIR/stop.sh" ]; then "$HOME_DIR/stop.sh" >/dev/null 2>&1 || true; fi

# Migrate an earlier "Course AI" install: keep its keys, password and database.
if [ -d "$OLD_HOME" ] && [ "$OLD_HOME" != "$HOME_DIR" ] && [ ! -f "$HOME_DIR/config/secrets.env" ] && [ -f "$OLD_HOME/config/secrets.env" ]; then
  info "Found the earlier Course AI install: moving its keys and data over"
  if [ -x "$OLD_HOME/stop.sh" ]; then "$OLD_HOME/stop.sh" >/dev/null 2>&1 || true; fi
  cp -Rp "$OLD_HOME/data/." "$HOME_DIR/data/" 2>/dev/null || true
  sed -e 's/^COURSEAI_ADMIN_/APP_ADMIN_/' "$OLD_HOME/config/secrets.env" > "$HOME_DIR/config/secrets.env"
  if [ -f "$HOME/Desktop/Course AI.command" ]; then mv "$HOME/Desktop/Course AI.command" "$OLD_HOME/Course AI.command.old" 2>/dev/null || true; fi
  MIGRATED=1
fi

# ---------------------------------------------------------------------------
step "1/5  Node.js"
# ---------------------------------------------------------------------------
node_ok() {
  "$1" -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit((a>20||(a===20&&b>=18))&&a<25?0:1)' 2>/dev/null
}
NODE_BIN=""
if [ -x "$HOME_DIR/runtime/node/bin/node" ] && node_ok "$HOME_DIR/runtime/node/bin/node"; then
  NODE_BIN="$HOME_DIR/runtime/node/bin/node"
elif command -v node >/dev/null && node_ok "$(command -v node)" && command -v npm >/dev/null; then
  NODE_BIN="$(command -v node)"
fi
if [ -z "$NODE_BIN" ]; then
  info "Downloading Node.js $NODE_LINE (private copy, does not touch your system)…"
  BASE="https://nodejs.org/dist/latest-${NODE_LINE}.x"
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  curl -fsSL "$BASE/SHASUMS256.txt" -o "$TMPD/SHASUMS256.txt"
  TARBALL="$(grep -o "node-v[0-9.]*-${NODE_OS}-${NODE_ARCH}\.tar\.gz" "$TMPD/SHASUMS256.txt" | head -n1)"
  [ -n "$TARBALL" ] || die "Could not find a Node.js download for ${NODE_OS}-${NODE_ARCH}"
  curl -fL --progress-bar "$BASE/$TARBALL" -o "$TMPD/$TARBALL"
  EXPECTED="$(grep " $TARBALL\$" "$TMPD/SHASUMS256.txt" | awk '{print $1}')"
  [ "$(sha256 "$TMPD/$TARBALL")" = "$EXPECTED" ] || die "Node.js download failed its checksum"
  mkdir -p "$HOME_DIR/runtime/node"
  tar -xzf "$TMPD/$TARBALL" -C "$HOME_DIR/runtime/node" --strip-components=1
  NODE_BIN="$HOME_DIR/runtime/node/bin/node"
fi
NODE_DIR="$(dirname "$NODE_BIN")"
export PATH="$NODE_DIR:$PATH"
NPM_BIN="$NODE_DIR/npm"; [ -x "$NPM_BIN" ] || NPM_BIN="$(command -v npm)"
info "Using Node $("$NODE_BIN" -v) at $NODE_BIN"

# ---------------------------------------------------------------------------
step "2/5  FreeLLMAPI router (download + build, takes 2-5 minutes)"
# ---------------------------------------------------------------------------
FL_DIR="$HOME_DIR/freellmapi"
FL_NEW="$HOME_DIR/freellmapi.new"
rm -rf "$FL_NEW"; mkdir -p "$FL_NEW"
if [ -n "${FREELLMAPI_SRC_DIR:-}" ]; then
  info "Copying FreeLLMAPI from $FREELLMAPI_SRC_DIR"
  (cd "$FREELLMAPI_SRC_DIR" && tar --exclude=node_modules --exclude=.git -cf - .) | (cd "$FL_NEW" && tar -xf -)
else
  info "Downloading github.com/$FL_REPO ($FL_REF)…"
  curl -fsSL "https://codeload.github.com/$FL_REPO/tar.gz/$FL_REF" | tar -xzf - -C "$FL_NEW" --strip-components=1 \
    || die "Could not download FreeLLMAPI. Check your internet connection."
fi
LOG_BUILD="$HOME_DIR/logs/build.log"
info "Installing packages… (log: $LOG_BUILD)"
(
  cd "$FL_NEW"
  export npm_config_fund=false npm_config_audit=false npm_config_update_notifier=false
  "$NPM_BIN" ci --no-audit --no-fund
  "$NPM_BIN" run build -w server
  "$NPM_BIN" run build -w client
) >"$LOG_BUILD" 2>&1 || { tail -n 30 "$LOG_BUILD" >&2; rm -rf "$FL_NEW"; die "FreeLLMAPI build failed (full log: $LOG_BUILD)"; }
rm -rf "$FL_DIR.old"; [ -d "$FL_DIR" ] && mv "$FL_DIR" "$FL_DIR.old"
mv "$FL_NEW" "$FL_DIR"; rm -rf "$FL_DIR.old"
info "FreeLLMAPI built ✓"

# ---------------------------------------------------------------------------
step "3/5  Assistant app"
# ---------------------------------------------------------------------------
cat > "$HOME_DIR/app/server.mjs" <<'ASSISTANT_EMBED_EOF'
@@SERVER_MJS@@
ASSISTANT_EMBED_EOF
cat > "$HOME_DIR/app/public/index.html" <<'ASSISTANT_EMBED_EOF'
@@INDEX_HTML@@
ASSISTANT_EMBED_EOF
cat > "$HOME_DIR/app/package.json" <<'ASSISTANT_EMBED_EOF'
@@APP_PACKAGE_JSON@@
ASSISTANT_EMBED_EOF
info "Installing file readers (Excel, Word, PDF)…"
(cd "$HOME_DIR/app" && "$NPM_BIN" install --no-audit --no-fund --omit=optional --ignore-scripts) >>"$LOG_BUILD" 2>&1 \
  || { tail -n 20 "$LOG_BUILD" >&2; die "Could not install the file readers (log: $LOG_BUILD)"; }
info "App installed ✓"

# ---------------------------------------------------------------------------
step "4/5  Settings, scripts and shortcut"
# ---------------------------------------------------------------------------
SECRETS="$HOME_DIR/config/secrets.env"
if [ ! -f "$SECRETS" ]; then
  umask 077
  ENC="$("$NODE_BIN" -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')"
  PASS="$("$NODE_BIN" -e 'console.log(require("crypto").randomBytes(9).toString("base64url"))')"
  cat > "$SECRETS" <<EOF
# Generated by the FreeLLM Assistant installer. Keep this file private.
ENCRYPTION_KEY=$ENC
APP_ADMIN_EMAIL=owner@assistant.local
APP_ADMIN_PASSWORD=$PASS
EOF
  umask 022
  info "Generated a private encryption key and dashboard password"
else
  info "Keeping existing keys and password"
fi
chmod 600 "$SECRETS"

# Our own processes were stopped above, so a busy port belongs to another program:
# move to the next free one instead of failing.
free_port() {
  "$NODE_BIN" -e '
    const net = require("net"); let p = Number(process.argv[1]); const avoid = Number(process.argv[2]);
    const tryPort = () => { if (p === avoid) p++; const s = net.createServer();
      s.once("error", () => { p++; if (p > Number(process.argv[1]) + 50) process.exit(1); tryPort(); });
      s.listen(p, "127.0.0.1", () => s.close(() => console.log(p))); };
    tryPort();' "$1" "${2:-0}"
}
WANT_FL="$FL_PORT"; WANT_APP="$APP_PORT"
FL_PORT="$(free_port "$FL_PORT")" || die "No free port found near $WANT_FL"
APP_PORT="$(free_port "$APP_PORT" "$FL_PORT")" || die "No free port found near $WANT_APP"
[ "$FL_PORT" = "$WANT_FL" ] || info "Port $WANT_FL is busy, FreeLLMAPI will use $FL_PORT"
[ "$APP_PORT" = "$WANT_APP" ] || info "Port $WANT_APP is busy, the Assistant will use $APP_PORT"

cat > "$HOME_DIR/config/runtime.env" <<EOF
NODE_BIN=$NODE_BIN
APP_PORT=$APP_PORT
FL_PORT=$FL_PORT
EOF

cat > "$HOME_DIR/start.sh" <<'EOF'
#!/usr/bin/env bash
# Starts FreeLLMAPI and the Assistant in the background, then opens the browser.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$H/config/runtime.env"; . "$H/config/secrets.env"; set +a
running() { [ -f "$H/run/$1.pid" ] && kill -0 "$(cat "$H/run/$1.pid")" 2>/dev/null; }
wait_for() { for _ in $(seq 1 "$2"); do curl -fsS -o /dev/null "$1" 2>/dev/null && return 0; sleep 1; done; return 1; }

if running freellmapi; then echo "• FreeLLMAPI already running"; else
  if curl -fsS -o /dev/null "http://127.0.0.1:$FL_PORT/api/ping" 2>/dev/null; then
    echo "✗ Port $FL_PORT is already used by another program. Close that program, or run the installer again (it picks a free port)." >&2; exit 1
  fi
  echo "• Starting FreeLLMAPI on http://127.0.0.1:$FL_PORT …"
  ADMIN_JSON="$("$NODE_BIN" -e 'console.log(JSON.stringify({admin:{email:process.env.APP_ADMIN_EMAIL,password:process.env.APP_ADMIN_PASSWORD}}))')"
  # cd first, then background node itself, so the saved PID is node's (stop.sh kills it).
  cd "$H/freellmapi"
  NODE_ENV=production HOST=127.0.0.1 PORT="$FL_PORT" \
    FREEAPI_DB_PATH="$H/data/freeapi.db" FREEAPI_CONFIG_JSON="$ADMIN_JSON" \
    nohup "$NODE_BIN" server/dist/index.js >>"$H/logs/freellmapi.log" 2>&1 &
  echo $! >"$H/run/freellmapi.pid"
  cd "$H"
  wait_for "http://127.0.0.1:$FL_PORT/api/ping" 60 || { echo "✗ FreeLLMAPI did not start. See $H/logs/freellmapi.log" >&2; tail -n 20 "$H/logs/freellmapi.log" >&2; exit 1; }
fi

if running app; then echo "• Assistant already running"; else
  echo "• Starting the Assistant on http://127.0.0.1:$APP_PORT …"
  APP_PORT="$APP_PORT" FREELLMAPI_URL="http://127.0.0.1:$FL_PORT" FREELLMAPI_DIR="$H/freellmapi" \
    FREEAPI_DB_PATH="$H/data/freeapi.db" APP_ADMIN_EMAIL="$APP_ADMIN_EMAIL" APP_ADMIN_PASSWORD="$APP_ADMIN_PASSWORD" \
    nohup "$NODE_BIN" "$H/app/server.mjs" >>"$H/logs/app.log" 2>&1 &
  echo $! >"$H/run/app.pid"
  wait_for "http://127.0.0.1:$APP_PORT/api/health" 20 || { echo "✗ The Assistant did not start. See $H/logs/app.log" >&2; tail -n 20 "$H/logs/app.log" >&2; exit 1; }
fi

echo ""
echo "✅ FreeLLM Assistant is running:"
echo "   Assistant:            http://127.0.0.1:$APP_PORT"
echo "   FreeLLMAPI dashboard: http://127.0.0.1:$FL_PORT   (login: $APP_ADMIN_EMAIL / $APP_ADMIN_PASSWORD)"
echo "   Stop it with:         $H/stop.sh"
if [ "${ASSISTANT_NO_OPEN:-0}" != "1" ]; then
  if command -v open >/dev/null; then open "http://127.0.0.1:$APP_PORT"
  elif command -v xdg-open >/dev/null; then xdg-open "http://127.0.0.1:$APP_PORT" >/dev/null 2>&1 || true; fi
fi
EOF

cat > "$HOME_DIR/stop.sh" <<'EOF'
#!/usr/bin/env bash
# Stops the Assistant and FreeLLMAPI.
H="$(cd "$(dirname "$0")" && pwd)"
for svc in app freellmapi; do
  f="$H/run/$svc.pid"
  if [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; then
    kill "$(cat "$f")" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$(cat "$f")" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$(cat "$f")" 2>/dev/null || true
    echo "• stopped $svc"
  fi
  rm -f "$f"
done
EOF

cat > "$HOME_DIR/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
# Removes FreeLLM Assistant completely (app, FreeLLMAPI, your data and keys).
H="$(cd "$(dirname "$0")" && pwd)"
read -r -p "Delete $H and everything in it? [y/N] " a
[ "$a" = "y" ] || [ "$a" = "Y" ] || { echo "Cancelled."; exit 0; }
"$H/stop.sh" || true
rm -f "$HOME/Desktop/FreeLLM Assistant.command"
rm -rf "$H"
echo "FreeLLM Assistant removed."
EOF
chmod +x "$HOME_DIR/start.sh" "$HOME_DIR/stop.sh" "$HOME_DIR/uninstall.sh"

if [ "$OS" = "Darwin" ] && [ -d "$HOME/Desktop" ]; then
  cat > "$SHORTCUT" <<EOF
#!/usr/bin/env bash
# Double-click to start FreeLLM Assistant.
"$HOME_DIR/start.sh"
echo ""
echo "You can close this window; the Assistant keeps running. To stop it: $HOME_DIR/stop.sh"
EOF
  chmod +x "$SHORTCUT"
  info "Desktop shortcut: FreeLLM Assistant.command (double-click to start)"
fi
info "Scripts: $HOME_DIR/start.sh · stop.sh · uninstall.sh"

# ---------------------------------------------------------------------------
step "5/5  Starting"
# ---------------------------------------------------------------------------
if [ "${ASSISTANT_NO_START:-0}" = "1" ]; then
  info "Skipped (ASSISTANT_NO_START=1). Start later with: $HOME_DIR/start.sh"
  exit 0
fi
ASSISTANT_NO_OPEN=1 "$HOME_DIR/start.sh"

# Add any free provider keys given as environment variables.
add_key() {
  [ -n "${2:-}" ] || return 0
  if curl -fsS -o /dev/null -X POST "http://127.0.0.1:$APP_PORT/api/keys" -H 'content-type: application/json' \
       --data "$("$NODE_BIN" -e 'console.log(JSON.stringify({platform:process.argv[1],key:process.argv[2]}))' "$1" "$2")"; then
    info "Added $1 key ✓"
  else
    info "Could not add $1 key (you can add it in the app under ⚙️ Settings)"
  fi
}
add_key google     "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"
add_key groq       "${GROQ_API_KEY:-}"
add_key cerebras   "${CEREBRAS_API_KEY:-}"
add_key openrouter "${OPENROUTER_API_KEY:-}"
add_key mistral    "${MISTRAL_API_KEY:-}"

if [ "${ASSISTANT_NO_OPEN:-0}" != "1" ]; then
  if command -v open >/dev/null; then open "http://127.0.0.1:$APP_PORT"
  elif command -v xdg-open >/dev/null; then xdg-open "http://127.0.0.1:$APP_PORT" >/dev/null 2>&1 || true; fi
fi
bold ""
bold "🎉 Done! FreeLLM Assistant is open at http://127.0.0.1:$APP_PORT"
if [ "${MIGRATED:-0}" = "1" ]; then
  info "Your keys and data were copied from ~/CourseAI. Once you're happy, you can delete that old folder."
fi
info "Next time, double-click \"FreeLLM Assistant\" on your Desktop (or run $HOME_DIR/start.sh)."
