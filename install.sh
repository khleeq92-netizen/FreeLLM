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
// FreeLLM Assistant — local web app that talks to a FreeLLMAPI router.
//
// Zero npm dependencies: only Node built-ins. It serves the single-page UI and
// forwards AI requests to FreeLLMAPI, so the browser never sees any API key.
// It listens on 127.0.0.1 only, so nothing outside this computer can reach it.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.APP_PORT || 3100);
const HOST = '127.0.0.1';
const FREELLMAPI_URL = (process.env.FREELLMAPI_URL || 'http://127.0.0.1:3001').replace(/\/+$/, '');
const FREELLMAPI_DIR = process.env.FREELLMAPI_DIR || '';
const DB_PATH = process.env.FREEAPI_DB_PATH || '';
const ADMIN_EMAIL = process.env.APP_ADMIN_EMAIL || '';
const ADMIN_PASSWORD = process.env.APP_ADMIN_PASSWORD || '';
const MAX_BODY = 20 * 1024 * 1024;

const INDEX_HTML = path.join(HERE, 'public', 'index.html');

// Browser libraries for reading files, installed into app/node_modules by the
// installer and served locally (no CDN needed). Fixed whitelist: nothing else is served.
const VENDOR = {
  'xlsx.js': 'xlsx/dist/xlsx.full.min.js',
  'mammoth.js': 'mammoth/mammoth.browser.min.js',
  'pdf.js': 'pdfjs-dist/build/pdf.min.js',
  'pdf.worker.js': 'pdfjs-dist/build/pdf.worker.min.js',
};

// Providers students can add a free key for from the Settings panel.
const KEY_PLATFORMS = new Set(['google', 'groq', 'cerebras', 'openrouter', 'mistral', 'cohere', 'nvidia', 'cloudflare', 'huggingface']);

// ---------------------------------------------------------------------------
// Credentials for FreeLLMAPI
// ---------------------------------------------------------------------------

let unifiedKey = process.env.FREELLMAPI_API_KEY || '';
let dashboardToken = '';

/** Reads the unified `freellmapi-…` key straight from FreeLLMAPI's SQLite DB. */
function readUnifiedKey() {
  if (process.env.FREELLMAPI_API_KEY) return process.env.FREELLMAPI_API_KEY;
  if (!FREELLMAPI_DIR || !DB_PATH || !fs.existsSync(DB_PATH)) return '';
  try {
    const req = createRequire(path.join(FREELLMAPI_DIR, 'package.json'));
    const Database = req('better-sqlite3');
    const db = new Database(DB_PATH, { readonly: true, fileMustExist: true });
    try {
      const row = db.prepare("SELECT value FROM settings WHERE key = 'unified_api_key'").get();
      return row?.value || '';
    } finally {
      db.close();
    }
  } catch (err) {
    console.error('[assistant] could not read the unified key:', err.message);
    return '';
  }
}

function getUnifiedKey(refresh = false) {
  if (!unifiedKey || refresh) unifiedKey = readUnifiedKey();
  return unifiedKey;
}

async function login() {
  if (!ADMIN_EMAIL || !ADMIN_PASSWORD) throw new Error('No dashboard login configured');
  const res = await fetch(`${FREELLMAPI_URL}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: ADMIN_EMAIL, password: ADMIN_PASSWORD }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.token) throw new Error(body?.error?.message || `Login failed (${res.status})`);
  dashboardToken = body.token;
  return dashboardToken;
}

/** Calls a FreeLLMAPI dashboard endpoint, logging in (again) when needed. */
async function dashboardFetch(pathname, init = {}) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const token = dashboardToken || (await login());
    const res = await fetch(`${FREELLMAPI_URL}${pathname}`, {
      ...init,
      headers: { 'content-type': 'application/json', ...(init.headers || {}), authorization: `Bearer ${token}` },
    });
    if (res.status === 401 && attempt === 0) { dashboardToken = ''; continue; }
    return res;
  }
  throw new Error('unreachable');
}

/** Calls a FreeLLMAPI /v1 endpoint with the unified key (re-reads it once on 401). */
async function v1Fetch(pathname, init = {}) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const key = getUnifiedKey(attempt > 0);
    if (!key) throw Object.assign(new Error('FreeLLMAPI is still starting up (no API key yet). Try again in a few seconds.'), { status: 503 });
    const res = await fetch(`${FREELLMAPI_URL}${pathname}`, {
      ...init,
      headers: { 'content-type': 'application/json', ...(init.headers || {}), authorization: `Bearer ${key}` },
    });
    if (res.status === 401 && attempt === 0) { await res.body?.cancel(); continue; }
    return res;
  }
  throw new Error('unreachable');
}

/** Turns on every no-key provider the catalog offers. Safe to call repeatedly. */
async function enableFreeProviders() {
  try {
    const res = await dashboardFetch('/api/keys/keyless-available/enable', { method: 'POST', body: '{}' });
    const body = await res.json().catch(() => ({}));
    return Array.isArray(body.enabled) ? body.enabled : [];
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('Request too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch { reject(Object.assign(new Error('Invalid JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

/** Only accept requests that come from this app's own page (blocks other websites). */
function sameOrigin(req) {
  const origin = req.headers.origin;
  if (!origin) return true;
  return origin === `http://${HOST}:${PORT}` || origin === `http://localhost:${PORT}`;
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

async function handleStatus(res) {
  const out = {
    freellmapi: false,
    models: 0,
    modelNames: [],
    dashboardUrl: FREELLMAPI_URL,
    dashboardEmail: ADMIN_EMAIL,
    dashboardPassword: ADMIN_PASSWORD,
  };
  try {
    const ping = await fetch(`${FREELLMAPI_URL}/api/ping`, { signal: AbortSignal.timeout(3000) });
    out.freellmapi = ping.ok;
  } catch { /* not running */ }
  if (out.freellmapi) {
    try {
      const r = await v1Fetch('/v1/models', { signal: AbortSignal.timeout(5000) });
      const body = await r.json();
      // Real models carry an execution_status; virtual entries (auto, fusion, Claude-name slots) do not.
      const real = (body.data || []).filter((m) => m.available === true && m.execution_status);
      out.models = real.length;
      out.modelNames = real.slice(0, 40).map((m) => m.name || m.id);
    } catch { /* keep zero */ }
    if (out.models === 0) {
      const enabled = await enableFreeProviders();
      out.justEnabled = enabled.length;
    }
  }
  sendJson(res, 200, out);
}

async function handleChat(req, res) {
  const body = await readBody(req);
  const messages = Array.isArray(body.messages) ? body.messages : null;
  if (!messages || messages.length === 0) return sendJson(res, 400, { error: { message: 'messages is required' } });

  const payload = {
    model: typeof body.model === 'string' && body.model ? body.model : 'auto',
    messages,
    stream: body.stream === true,
  };
  if (typeof body.temperature === 'number') payload.temperature = body.temperature;
  if (typeof body.max_tokens === 'number') payload.max_tokens = body.max_tokens;

  const started = Date.now();
  const controller = new AbortController();
  res.on('close', () => { if (!res.writableEnded) controller.abort(); });

  let upstream;
  try {
    upstream = await v1Fetch('/v1/chat/completions', {
      method: 'POST',
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
  } catch (err) {
    return sendJson(res, err.status || 502, { error: { message: friendlyNetworkError(err) } });
  }

  const routedVia = upstream.headers.get('x-routed-via') || '';
  const headers = {
    'content-type': upstream.headers.get('content-type') || 'application/json',
    'cache-control': 'no-store',
    'x-routed-via': routedVia,
    'x-first-byte-ms': String(Date.now() - started),
  };
  res.writeHead(upstream.status, headers);
  if (!upstream.body) return res.end();
  try {
    for await (const chunk of upstream.body) res.write(chunk);
  } catch { /* client went away or upstream aborted */ }
  res.end();
}

async function handleAddKey(req, res) {
  const body = await readBody(req);
  const platform = String(body.platform || '').trim();
  const key = String(body.key || '').trim();
  if (!KEY_PLATFORMS.has(platform)) return sendJson(res, 400, { error: { message: 'Unknown provider' } });
  if (key.length < 8) return sendJson(res, 400, { error: { message: 'That key looks too short' } });
  try {
    const r = await dashboardFetch('/api/keys', { method: 'POST', body: JSON.stringify({ platform, key, label: 'added from FreeLLM Assistant' }) });
    const out = await r.json().catch(() => ({}));
    if (!r.ok) return sendJson(res, r.status, { error: { message: out?.error?.message || `Could not add key (${r.status})` } });
    sendJson(res, 200, { ok: true, platform, modelsAvailable: out.modelsAvailable ?? null, maskedKey: out.maskedKey ?? '' });
  } catch (err) {
    sendJson(res, 502, { error: { message: friendlyNetworkError(err) } });
  }
}

function friendlyNetworkError(err) {
  if (err?.status) return err.message;
  if (err?.name === 'AbortError') return 'Request cancelled';
  return `Cannot reach FreeLLMAPI at ${FREELLMAPI_URL}. Is it running? (${err?.cause?.code || err?.message || 'network error'})`;
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${HOST}:${PORT}`);
    if (req.method !== 'GET' && !sameOrigin(req)) return sendJson(res, 403, { error: { message: 'Forbidden origin' } });

    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      const html = fs.readFileSync(INDEX_HTML);
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      return res.end(html);
    }
    if (req.method === 'GET' && url.pathname.startsWith('/vendor/')) {
      const rel = VENDOR[url.pathname.slice('/vendor/'.length)];
      const file = rel && path.join(HERE, 'node_modules', rel);
      if (!file || !fs.existsSync(file)) return sendJson(res, 404, { error: { message: 'File reader library missing. Re-run the installer.' } });
      res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'max-age=86400' });
      return fs.createReadStream(file).pipe(res);
    }
    if (req.method === 'GET' && url.pathname === '/api/health') return sendJson(res, 200, { ok: true });
    if (req.method === 'GET' && url.pathname === '/api/status') return await handleStatus(res);
    if (req.method === 'POST' && url.pathname === '/api/chat') return await handleChat(req, res);
    if (req.method === 'POST' && url.pathname === '/api/keys') return await handleAddKey(req, res);
    if (req.method === 'POST' && url.pathname === '/api/enable-free') return sendJson(res, 200, { enabled: await enableFreeProviders() });

    sendJson(res, 404, { error: { message: 'Not found' } });
  } catch (err) {
    if (!res.headersSent) sendJson(res, err.status || 500, { error: { message: err.message || 'Server error' } });
    else res.end();
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[assistant] FreeLLM Assistant running at http://${HOST}:${PORT} (FreeLLMAPI: ${FREELLMAPI_URL})`);
  // Best effort: make sure the no-key providers are on, so it works with zero signups.
  setTimeout(() => { enableFreeProviders().then((e) => e.length && console.log(`[assistant] enabled free no-key providers: ${e.join(', ')}`)); }, 1500);
});
ASSISTANT_EMBED_EOF
cat > "$HOME_DIR/app/public/index.html" <<'ASSISTANT_EMBED_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FreeLLM Assistant</title>
<style>
  :root {
    --bg: #f6f7fb; --panel: #ffffff; --panel-2: #f1f3f9; --text: #1b1f2a; --muted: #5d6475;
    --border: #dfe3ee; --accent: #4f46e5; --accent-text: #ffffff; --accent-soft: #eef0ff;
    --ok: #15803d; --ok-soft: #e7f6ec; --warn: #b45309; --warn-soft: #fdf3e3; --bad: #b91c1c; --bad-soft: #fdecec;
    --shadow: 0 1px 2px rgba(20,24,40,.06), 0 4px 16px rgba(20,24,40,.05);
    --radius: 12px; --mono: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #0f1117; --panel: #171a23; --panel-2: #1e2230; --text: #e7e9f0; --muted: #9aa1b4;
      --border: #2a2f3e; --accent: #818cf8; --accent-text: #0f1117; --accent-soft: #23264a;
      --ok: #4ade80; --ok-soft: #13291c; --warn: #fbbf24; --warn-soft: #2d2410; --bad: #f87171; --bad-soft: #2e1515;
      --shadow: none;
    }
  }
  :root[data-theme="dark"] {
    --bg: #0f1117; --panel: #171a23; --panel-2: #1e2230; --text: #e7e9f0; --muted: #9aa1b4;
    --border: #2a2f3e; --accent: #818cf8; --accent-text: #0f1117; --accent-soft: #23264a;
    --ok: #4ade80; --ok-soft: #13291c; --warn: #fbbf24; --warn-soft: #2d2410; --bad: #f87171; --bad-soft: #2e1515;
    --shadow: none;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; }
  body { background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  button, input, select, textarea { font: inherit; color: inherit; }
  a { color: var(--accent); }

  header { display: flex; align-items: center; gap: 12px; padding: 12px 20px; border-bottom: 1px solid var(--border); background: var(--panel); position: sticky; top: 0; z-index: 5; flex-wrap: wrap; }
  header h1 { font-size: 18px; margin: 0; letter-spacing: -.01em; }
  header .sub { color: var(--muted); font-size: 13px; }
  .spacer { flex: 1; }
  .pill { display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px; border-radius: 999px; font-size: 13px; background: var(--panel-2); color: var(--muted); border: 1px solid var(--border); }
  .pill .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); }
  .pill.ok { background: var(--ok-soft); color: var(--ok); border-color: transparent; } .pill.ok .dot { background: var(--ok); }
  .pill.warn { background: var(--warn-soft); color: var(--warn); border-color: transparent; } .pill.warn .dot { background: var(--warn); }
  .pill.bad { background: var(--bad-soft); color: var(--bad); border-color: transparent; } .pill.bad .dot { background: var(--bad); }

  .btn { border: 1px solid var(--border); background: var(--panel); padding: 7px 14px; border-radius: 9px; cursor: pointer; }
  .btn:hover { background: var(--panel-2); }
  .btn.primary { background: var(--accent); color: var(--accent-text); border-color: var(--accent); font-weight: 600; }
  .btn.primary:hover { filter: brightness(1.07); }
  .btn:disabled { opacity: .55; cursor: not-allowed; }
  .btn.small { padding: 4px 10px; font-size: 13px; }

  main { display: grid; grid-template-columns: minmax(260px, 340px) 1fr; gap: 18px; padding: 18px 20px 40px; max-width: 1500px; margin: 0 auto; }
  @media (max-width: 900px) { main { grid-template-columns: 1fr; padding: 14px 16px 40px; } }
  .card { background: var(--panel); border: 1px solid var(--border); border-radius: var(--radius); box-shadow: var(--shadow); padding: 16px; min-width: 0; }
  .card h2 { font-size: 15px; margin: 0 0 4px; }
  .hint { color: var(--muted); font-size: 13px; margin: 0 0 10px; }
  textarea { width: 100%; border: 1px solid var(--border); background: var(--panel-2); border-radius: 9px; padding: 10px; resize: vertical; }
  textarea:focus, input:focus, select:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
  .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .row.between { justify-content: space-between; }
  .grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 10px; margin-bottom: 10px; }
  .field { display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--muted); min-width: 0; }
  .field select, .field input { color: var(--text); }
  select, input[type=text], input[type=password], input[type=number] { border: 1px solid var(--border); background: var(--panel-2); border-radius: 9px; padding: 7px 10px; max-width: 100%; }

  /* files */
  .drop { display: block; border: 2px dashed var(--border); border-radius: 12px; padding: 18px 12px; text-align: center; cursor: pointer; color: var(--muted); transition: .15s; }
  .drop:hover, .drop.over { border-color: var(--accent); background: var(--accent-soft); color: var(--text); }
  .drop b { color: var(--text); }
  .filelist { list-style: none; margin: 12px 0 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
  .file { display: grid; grid-template-columns: auto 1fr auto; gap: 8px; align-items: center; padding: 8px 10px; border: 1px solid var(--border); border-radius: 10px; background: var(--panel-2); }
  .file .name { font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .file .info { font-size: 12px; color: var(--muted); }
  .file button { border: none; background: none; cursor: pointer; color: var(--muted); font-size: 16px; padding: 2px 4px; }
  .file button:hover { color: var(--bad); }
  .file.err { background: var(--bad-soft); }

  .tabs { display: flex; gap: 2px; border-bottom: 1px solid var(--border); margin: -4px -4px 14px; padding: 0 4px; overflow-x: auto; }
  .tab { border: none; background: none; padding: 9px 11px; cursor: pointer; color: var(--muted); border-bottom: 2px solid transparent; white-space: nowrap; }
  .tab[aria-selected="true"] { color: var(--text); border-bottom-color: var(--accent); font-weight: 600; }
  .panel { display: none; } .panel.active { display: block; }

  .chatlog { display: flex; flex-direction: column; gap: 12px; min-height: 260px; max-height: 60vh; overflow-y: auto; padding: 4px 2px 8px; }
  .msg { max-width: 92%; padding: 10px 13px; border-radius: 12px; overflow-wrap: anywhere; }
  .msg.user { align-self: flex-end; background: var(--accent); color: var(--accent-text); white-space: pre-wrap; }
  .msg.ai { align-self: flex-start; background: var(--panel-2); border: 1px solid var(--border); }
  .msg.err { align-self: flex-start; background: var(--bad-soft); color: var(--bad); }
  .meta { font-size: 12px; color: var(--muted); margin-top: 6px; font-family: var(--mono); overflow-wrap: anywhere; }
  .empty { color: var(--muted); text-align: center; padding: 40px 10px; }
  .composer { display: flex; gap: 8px; margin-top: 10px; }
  .composer textarea { min-height: 46px; height: 46px; }
  .ctx { font-size: 12px; color: var(--muted); margin-top: 6px; }

  .md h1, .md h2, .md h3 { font-size: 1.05em; margin: .8em 0 .3em; }
  .md p { margin: .4em 0; } .md ul, .md ol { margin: .3em 0; padding-left: 1.3em; }
  .md code { font-family: var(--mono); font-size: .9em; background: var(--panel); border: 1px solid var(--border); padding: 0 4px; border-radius: 4px; }
  .md pre { background: var(--panel); border: 1px solid var(--border); padding: 10px; border-radius: 8px; overflow-x: auto; }
  .md pre code { border: none; padding: 0; }
  .md table { border-collapse: collapse; margin: .5em 0; display: block; overflow-x: auto; }
  .md td, .md th { border: 1px solid var(--border); padding: 4px 8px; }

  .output { background: var(--panel-2); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; margin-top: 12px; min-height: 80px; max-height: 60vh; overflow-y: auto; overflow-wrap: anywhere; }
  .outbar { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-top: 8px; }
  .progress { font-size: 13px; color: var(--muted); }

  .tablewrap { overflow: auto; max-height: 50vh; border: 1px solid var(--border); border-radius: 10px; margin-top: 10px; }
  table.data { border-collapse: collapse; font-size: 13px; width: max-content; min-width: 100%; }
  table.data th, table.data td { border-bottom: 1px solid var(--border); padding: 5px 9px; text-align: left; max-width: 320px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  table.data th { position: sticky; top: 0; background: var(--panel-2); font-weight: 600; }
  table.data td.n { color: var(--muted); }

  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; margin-bottom: 14px; }
  .stat { background: var(--panel-2); border: 1px solid var(--border); border-radius: 10px; padding: 10px 12px; }
  .stat .v { font-size: 22px; font-weight: 700; }
  .stat .l { font-size: 12px; color: var(--muted); }
  table.log { width: 100%; border-collapse: collapse; font-size: 13px; }
  table.log th, table.log td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--border); white-space: nowrap; }
  table.log th { color: var(--muted); font-weight: 600; }
  td.mono { font-family: var(--mono); }
  .ok-t { color: var(--ok); } .bad-t { color: var(--bad); } .warn-t { color: var(--warn); }
  .section-title { font-weight: 600; margin: 16px 0 6px; }

  dialog { border: 1px solid var(--border); border-radius: 14px; background: var(--panel); color: var(--text); padding: 0; width: min(560px, calc(100vw - 32px)); }
  dialog::backdrop { background: rgba(0,0,0,.4); }
  .dlg { padding: 18px; }
  .dlg h3 { margin: 0 0 6px; }
  .keyrow { display: grid; grid-template-columns: 150px 1fr auto; gap: 8px; align-items: center; margin: 8px 0; }
  @media (max-width: 520px) { .keyrow { grid-template-columns: 1fr; } }
  .notice { border-radius: 10px; padding: 10px 12px; font-size: 14px; margin-bottom: 12px; }
  .notice.warn { background: var(--warn-soft); color: var(--warn); }
  .notice.info { background: var(--accent-soft); }
  .hidden { display: none !important; }
  .spin { display: inline-block; width: 12px; height: 12px; border: 2px solid currentColor; border-right-color: transparent; border-radius: 50%; animation: s .7s linear infinite; vertical-align: -2px; }
  @keyframes s { to { transform: rotate(360deg); } }
</style>
</head>
<body>
<header>
  <div>
    <h1>🤖 FreeLLM Assistant</h1>
    <div class="sub">Chat, write, translate, summarise and work on your files using free AI. It runs on your own Mac.</div>
  </div>
  <div class="spacer"></div>
  <span id="status" class="pill"><span class="dot"></span><span id="statusText">Checking…</span></span>
  <label class="row" style="gap:6px;font-size:13px;color:var(--muted)">AI mode
    <select id="mode" title="How the router chooses a model">
      <option value="auto:fast">Fast</option>
      <option value="auto">Balanced</option>
      <option value="auto:smart">Smartest available</option>
      <option value="auto:reliable">Most reliable</option>
      <option value="fusion">Fusion (several AIs + judge, slow)</option>
    </select>
  </label>
  <button class="btn" id="settingsBtn">⚙️ Settings</button>
</header>

<main>
  <aside class="card">
    <div class="row between"><h2>📎 Your files</h2><span class="hint" style="margin:0" id="fileCount"></span></div>
    <p class="hint">Excel (.xlsx, .xls, .csv), Word (.docx), PDF and text files. Ticked files are used by Chat, Write and Summarise.</p>
    <label class="drop" id="drop" for="fileInput">
      <div style="font-size:26px">⬆️</div>
      <b>Click to upload</b> or drag files here
      <div style="font-size:12px;margin-top:4px">Files are read on this computer and never uploaded anywhere</div>
    </label>
    <input type="file" id="fileInput" multiple class="hidden"
      accept=".xlsx,.xls,.xlsm,.ods,.csv,.tsv,.docx,.pdf,.txt,.md,.markdown,.json,.html,.htm,.xml,.log,.rtf">
    <ul class="filelist" id="fileList"></ul>
    <div class="row" style="margin-top:10px">
      <button class="btn small" id="sampleBtn">✨ Add sample files</button>
      <button class="btn small" id="clearFiles">Remove all</button>
    </div>
  </aside>

  <section class="card">
    <div class="tabs" role="tablist">
      <button class="tab" role="tab" data-tab="chat" aria-selected="true">💬 Chat</button>
      <button class="tab" role="tab" data-tab="write" aria-selected="false">✍️ Write</button>
      <button class="tab" role="tab" data-tab="translate" aria-selected="false">🌐 Translate</button>
      <button class="tab" role="tab" data-tab="summary" aria-selected="false">📄 Summarise</button>
      <button class="tab" role="tab" data-tab="excel" aria-selected="false">📊 Excel / Data</button>
      <button class="tab" role="tab" data-tab="log" aria-selected="false">📈 Log</button>
    </div>

    <div id="noModels" class="notice warn hidden"></div>

    <!-- CHAT -->
    <div class="panel active" data-panel="chat">
      <div class="chatlog" id="chatlog"></div>
      <div class="ctx" id="chatCtx"></div>
      <div class="composer">
        <textarea id="question" placeholder="Ask anything… (Enter to send, Shift+Enter for a new line)"></textarea>
        <button class="btn primary" id="askBtn">Send</button>
      </div>
      <div class="row" style="margin-top:8px">
        <button class="btn small" data-quick="Summarise the attached files in a few bullet points.">Summarise my files</button>
        <button class="btn small" data-quick="What are the most important numbers, facts and dates in the attached files?">Key facts & numbers</button>
        <button class="btn small" data-quick="Based on the attached files, what should I do next? Give a short action list.">Action items</button>
        <button class="btn small" id="newChat">New chat</button>
      </div>
    </div>

    <!-- WRITE -->
    <div class="panel" data-panel="write">
      <div class="grid2">
        <label class="field">What to write
          <select id="wType">
            <option>Email</option><option>Social media post</option><option>Blog / article</option><option>Report</option>
            <option>Letter</option><option>Announcement</option><option>Proposal</option><option>Product or service description</option>
            <option>Speech</option><option>Rewrite / improve my text</option><option>Other</option>
          </select></label>
        <label class="field">Tone
          <select id="wTone"><option>Professional</option><option>Friendly</option><option>Persuasive</option><option>Formal</option><option>Simple and clear</option><option>Inspiring</option></select></label>
        <label class="field">Length
          <select id="wLen"><option value="short">Short</option><option value="medium" selected>Medium</option><option value="long">Long</option></select></label>
        <label class="field">Language
          <select id="wLang" class="langSel"></select></label>
      </div>
      <textarea id="wTopic" rows="5" placeholder="Describe what you need. For example: an email inviting volunteers to our food drive on Saturday 10am at the community centre. Or paste the text you want improved."></textarea>
      <div class="row" style="margin-top:8px">
        <label class="row" style="gap:6px;font-size:14px"><input type="checkbox" id="wUseFiles"> Use my ticked files as reference</label>
        <span class="spacer"></span>
        <button class="btn primary" id="wBtn">Write it</button>
      </div>
      <div class="output md" id="wOut"><span class="hint">Your text will appear here.</span></div>
      <div class="outbar" data-for="wOut"></div>
    </div>

    <!-- TRANSLATE -->
    <div class="panel" data-panel="translate">
      <div class="grid2">
        <label class="field">Translate
          <select id="tSource"><option value="text">Text I paste below</option></select></label>
        <label class="field">Into
          <select id="tLang" class="langSel"></select></label>
      </div>
      <textarea id="tText" rows="6" placeholder="Paste the text to translate… (or pick one of your files above)"></textarea>
      <div class="row" style="margin-top:8px">
        <span class="hint" style="margin:0">Long documents are translated piece by piece. For spreadsheets, use the Excel tab.</span>
        <span class="spacer"></span>
        <button class="btn primary" id="tBtn">Translate</button>
      </div>
      <div class="progress" id="tProg"></div>
      <div class="output md" id="tOut"><span class="hint">The translation will appear here.</span></div>
      <div class="outbar" data-for="tOut"></div>
    </div>

    <!-- SUMMARISE -->
    <div class="panel" data-panel="summary">
      <div class="grid2">
        <label class="field">Document
          <select id="sSource"></select></label>
        <label class="field">Style
          <select id="sStyle">
            <option value="bullets">Key points (bullets)</option>
            <option value="exec">Executive summary</option>
            <option value="detailed">Detailed summary by section</option>
            <option value="actions">Action items & decisions</option>
            <option value="simple">Explain in simple words</option>
          </select></label>
        <label class="field">Language
          <select id="sLang" class="langSel"></select></label>
      </div>
      <div class="row">
        <span class="hint" style="margin:0">Long documents are summarised in parts, then combined.</span>
        <span class="spacer"></span>
        <button class="btn primary" id="sBtn">Summarise</button>
      </div>
      <div class="progress" id="sProg"></div>
      <div class="output md" id="sOut"><span class="hint">Upload a file on the left, then click Summarise.</span></div>
      <div class="outbar" data-for="sOut"></div>
    </div>

    <!-- EXCEL -->
    <div class="panel" data-panel="excel">
      <div class="grid2">
        <label class="field">Spreadsheet
          <select id="xFile"></select></label>
        <label class="field">Sheet
          <select id="xSheet"></select></label>
      </div>
      <div class="hint" id="xInfo">Upload an Excel or CSV file on the left to start.</div>
      <div class="tablewrap hidden" id="xPreviewWrap"><table class="data" id="xPreview"></table></div>

      <div class="section-title">❓ Ask about this data</div>
      <div class="composer" style="margin-top:0">
        <textarea id="xQ" placeholder="e.g. Which region had the highest sales? What is the total for March? Any unusual entries?"></textarea>
        <button class="btn primary" id="xAskBtn">Ask</button>
      </div>
      <div class="output md hidden" id="xAnswer"></div>
      <div class="outbar" data-for="xAnswer"></div>

      <div class="section-title">🛠️ Change the data (AI edits every row, you download a new Excel file)</div>
      <textarea id="xEdit" rows="2" placeholder="e.g. Translate the Product column into Urdu. Or: add a column 'Category' that classifies each row. Or: fix spelling and capitalisation in all names."></textarea>
      <div class="row" style="margin-top:8px">
        <button class="btn small" data-xq="Translate all text cells into English. Keep numbers, dates and the header row's meaning unchanged.">Translate to English</button>
        <button class="btn small" data-xq="Add a new last column called 'Category' that classifies each row into a short, sensible category.">Add a Category column</button>
        <button class="btn small" data-xq="Fix spelling, extra spaces and capitalisation in all text cells. Do not change numbers.">Clean up text</button>
        <button class="btn small" data-xq="Add a new last column called 'Summary' with a one-sentence summary of each row.">Add a Summary column</button>
        <span class="spacer"></span>
        <button class="btn primary" id="xEditBtn">Apply to all rows</button>
      </div>
      <div class="progress" id="xProg"></div>
      <div class="tablewrap hidden" id="xResultWrap"><table class="data" id="xResult"></table></div>
      <div class="row hidden" id="xResultBar" style="margin-top:8px">
        <button class="btn primary small" id="xDlXlsx">⬇️ Download Excel (.xlsx)</button>
        <button class="btn small" id="xDlCsv">⬇️ Download CSV</button>
        <button class="btn small" id="xKeep">➕ Add result to my files</button>
      </div>
    </div>

    <!-- LOG -->
    <div class="panel" data-panel="log">
      <p class="hint">Every AI request is logged here so you can see how well the free AI performs: success rate, speed and which provider answered.</p>
      <div class="stats" id="stats"></div>
      <div class="row" style="margin-bottom:10px">
        <button class="btn small" id="exportBtn">⬇️ Export CSV</button>
        <button class="btn small" id="resetLog">Clear log</button>
      </div>
      <div style="overflow-x:auto"><table class="log">
        <thead><tr><th>Time</th><th>Task</th><th>Mode</th><th>Answered by</th><th>Seconds</th><th>Result</th></tr></thead>
        <tbody id="logBody"></tbody>
      </table></div>
    </div>
  </section>
</main>

<dialog id="settings">
  <div class="dlg">
    <h3>Settings</h3>
    <div class="notice info">Works without any signup: FreeLLMAPI turns on its no-key providers automatically. <b>For much faster and better answers</b>, add one or more <b>free</b> keys below. Each takes about a minute to get and needs no credit card.</div>
    <div id="keyRows"></div>
    <p class="hint" id="keyMsg"></p>
    <hr style="border:none;border-top:1px solid var(--border);margin:14px 0">
    <h3 style="font-size:15px">FreeLLMAPI dashboard (advanced)</h3>
    <p class="hint">See every model and provider, its usage and analytics: <a id="dashLink" href="#" target="_blank" rel="noopener">open dashboard</a><br>
      Login: <code id="dashEmail"></code> / <code id="dashPass"></code></p>
    <div class="row between" style="margin-top:12px">
      <label class="row" style="gap:6px;font-size:13px">Theme
        <select id="theme"><option value="">System</option><option value="light">Light</option><option value="dark">Dark</option></select>
      </label>
      <button class="btn" id="closeSettings">Close</button>
    </div>
  </div>
</dialog>

<script>
(() => {
  'use strict';
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];

  const CONTEXT_BUDGET = 24000;   // characters of file content sent with a chat/write request
  const CHUNK = 12000;            // characters per piece when summarising long documents
  const T_CHUNK = 4000;           // characters per piece when translating
  const ROW_BATCH = 40;           // spreadsheet rows per AI request when editing
  const MAX_EDIT_ROWS = 2000;
  const LANGS = ['English', 'Hindi', 'Urdu', 'Marathi', 'Arabic', 'Punjabi', 'Bengali', 'Persian', 'Turkish', 'French', 'Spanish', 'Portuguese', 'German', 'Italian', 'Dutch', 'Russian', 'Ukrainian', 'Chinese (Simplified)', 'Japanese', 'Korean', 'Indonesian', 'Malay', 'Swahili', 'Pashto', 'Sindhi', 'Tamil', 'Telugu'];

  // ---------- safe storage ----------
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); return true; } catch { return false; } },
  };

  // ---------- theme ----------
  const applyTheme = (t) => { if (t) document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme; };
  applyTheme(store.get('theme', ''));
  $('#theme').value = store.get('theme', '');
  $('#theme').onchange = (e) => { store.set('theme', e.target.value); applyTheme(e.target.value); };

  // ---------- small helpers ----------
  function esc(s) { return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
  const fmtSize = (n) => n < 1024 ? n + ' B' : n < 1048576 ? (n / 1024).toFixed(0) + ' KB' : (n / 1048576).toFixed(1) + ' MB';
  const uid = () => Math.random().toString(36).slice(2, 10);
  const loadScript = (src) => new Promise((ok, fail) => {
    const s = document.createElement('script'); s.src = src; s.onload = ok;
    s.onerror = () => fail(new Error('Could not load the file reader (' + src + '). Re-run the installer.'));
    document.head.appendChild(s);
  });
  const libs = {};
  async function lib(name) {
    if (!libs[name]) {
      libs[name] = (async () => {
        if (name === 'xlsx') { await loadScript('/vendor/xlsx.js'); return window.XLSX; }
        if (name === 'mammoth') { await loadScript('/vendor/mammoth.js'); return window.mammoth; }
        if (name === 'pdf') { await loadScript('/vendor/pdf.js'); window.pdfjsLib.GlobalWorkerOptions.workerSrc = '/vendor/pdf.worker.js'; return window.pdfjsLib; }
      })();
      libs[name].catch(() => { delete libs[name]; });
    }
    return libs[name];
  }

  // Tiny, safe markdown renderer: escapes everything first, then adds formatting.
  function md(src) {
    const blocks = [];
    let s = esc(src).replace(/```[^\n]*\n([\s\S]*?)(```|$)/g, (_, code) => { blocks.push(code); return `\u0000${blocks.length - 1}\u0000`; });
    const inline = (t) => t
      .replace(/`([^`]+)`/g, '<code>$1</code>')
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    const out = []; let list = null; let table = null;
    const closeList = () => { if (list) { out.push(`</${list}>`); list = null; } };
    const closeTable = () => { if (table) { out.push('<table>' + table.map((r, i) => '<tr>' + r.map((c) => i === 0 ? `<th>${inline(c)}</th>` : `<td>${inline(c)}</td>`).join('') + '</tr>').join('') + '</table>'); table = null; } };
    for (const line of s.split('\n')) {
      let m;
      if (/^\s*\|.*\|\s*$/.test(line)) {
        closeList();
        if (/^\s*\|[\s:|-]+\|\s*$/.test(line)) continue;
        (table ||= []).push(line.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim()));
        continue;
      }
      closeTable();
      if (/^\u0000\d+\u0000$/.test(line.trim())) { closeList(); out.push(line.trim()); }
      else if ((m = line.match(/^\s*#{1,6}\s+(.*)$/))) { closeList(); out.push(`<h3>${inline(m[1])}</h3>`); }
      else if ((m = line.match(/^\s*[-*•]\s+(.*)$/))) { if (list !== 'ul') { closeList(); out.push('<ul>'); list = 'ul'; } out.push(`<li>${inline(m[1])}</li>`); }
      else if ((m = line.match(/^\s*\d+[.)]\s+(.*)$/))) { if (list !== 'ol') { closeList(); out.push('<ol>'); list = 'ol'; } out.push(`<li>${inline(m[1])}</li>`); }
      else if (/^\s*-{3,}\s*$/.test(line)) { closeList(); out.push('<hr>'); }
      else if (!line.trim()) { closeList(); }
      else { closeList(); out.push(`<p>${inline(line)}</p>`); }
    }
    closeList(); closeTable();
    return out.join('').replace(/\u0000(\d+)\u0000/g, (_, i) => `<pre><code>${blocks[i]}</code></pre>`);
  }

  // ---------- language selects ----------
  $$('.langSel').forEach((sel) => {
    sel.innerHTML = LANGS.map((l) => `<option>${l}</option>`).join('') + '<option value="__other">Other…</option>';
    const key = 'lang:' + sel.id;
    sel.value = store.get(key, sel.id === 'tLang' ? 'Hindi' : 'English');
    sel.onchange = () => {
      if (sel.value === '__other') {
        const l = (prompt('Which language?') || '').trim();
        if (l) { const o = document.createElement('option'); o.textContent = l; sel.insertBefore(o, sel.lastElementChild); sel.value = l; }
        else sel.value = 'English';
      }
      store.set(key, sel.value);
    };
  });

  // =====================================================================
  // FILES
  // =====================================================================
  /** @type {{id:string,name:string,size:number,kind:'text'|'sheet',text?:string,sheets?:Record<string,string[][]>,on:boolean,err?:string}[]} */
  let files = store.get('files', []);
  const saveFiles = () => { if (!store.set('files', files)) store.set('files', []); };
  const textFiles = () => files.filter((f) => !f.err);
  const sheetFiles = () => files.filter((f) => f.kind === 'sheet' && !f.err);

  function renderFiles() {
    const ul = $('#fileList');
    ul.innerHTML = files.map((f) => `
      <li class="file ${f.err ? 'err' : ''}" data-id="${f.id}">
        <input type="checkbox" ${f.on && !f.err ? 'checked' : ''} ${f.err ? 'disabled' : ''} title="Use this file in Chat / Write / Summarise">
        <div style="min-width:0"><div class="name" title="${esc(f.name)}">${f.kind === 'sheet' ? '📊' : '📄'} ${esc(f.name)}</div>
          <div class="info">${f.err ? esc(f.err) : fileInfo(f)}</div></div>
        <button title="Remove">✕</button>
      </li>`).join('');
    $$('.file', ul).forEach((li) => {
      const f = files.find((x) => x.id === li.dataset.id);
      $('input', li).onchange = (e) => { f.on = e.target.checked; saveFiles(); updateCtx(); };
      $('button', li).onclick = () => { files = files.filter((x) => x !== f); saveFiles(); renderFiles(); };
    });
    $('#fileCount').textContent = files.length ? `${files.length} file${files.length === 1 ? '' : 's'}` : '';
    refreshSelectors(); updateCtx();
  }
  function fileInfo(f) {
    if (f.kind === 'sheet') {
      const names = Object.keys(f.sheets || {});
      const rows = names.reduce((a, n) => a + Math.max(0, f.sheets[n].length - 1), 0);
      return `${names.length} sheet${names.length === 1 ? '' : 's'} · ${rows.toLocaleString()} rows · ${fmtSize(f.size)}`;
    }
    return `${(f.text || '').length.toLocaleString()} characters · ${fmtSize(f.size)}`;
  }

  async function readFile(file) {
    const name = file.name; const lower = name.toLowerCase(); const ext = lower.split('.').pop();
    const base = { id: uid(), name, size: file.size, on: true };
    try {
      if (['xlsx', 'xls', 'xlsm', 'ods', 'csv', 'tsv'].includes(ext)) {
        const XLSX = await lib('xlsx');
        const wb = ext === 'csv' || ext === 'tsv'
          ? XLSX.read(await file.text(), { type: 'string', raw: true, FS: ext === 'tsv' ? '\t' : undefined })
          : XLSX.read(await file.arrayBuffer(), { type: 'array', cellDates: true });
        const sheets = {};
        for (const sn of wb.SheetNames) {
          const rows = XLSX.utils.sheet_to_json(wb.Sheets[sn], { header: 1, defval: '', raw: false, blankrows: false })
            .map((r) => r.map((c) => String(c ?? '')));
          if (rows.length) sheets[sn] = rows;
        }
        if (!Object.keys(sheets).length) throw new Error('the spreadsheet is empty');
        return { ...base, kind: 'sheet', sheets };
      }
      if (ext === 'docx') {
        const mammoth = await lib('mammoth');
        const r = await mammoth.extractRawText({ arrayBuffer: await file.arrayBuffer() });
        return { ...base, kind: 'text', text: r.value.trim() };
      }
      if (ext === 'pdf') {
        const pdfjs = await lib('pdf');
        const pdf = await pdfjs.getDocument({ data: await file.arrayBuffer() }).promise;
        const pages = [];
        for (let i = 1; i <= pdf.numPages; i++) {
          const c = await (await pdf.getPage(i)).getTextContent();
          pages.push(c.items.map((it) => it.str).join(' '));
        }
        const text = pages.join('\n\n').trim();
        if (!text) throw new Error('no text found (scanned PDFs are not supported yet)');
        return { ...base, kind: 'text', text };
      }
      if (['doc', 'ppt', 'pptx'].includes(ext)) throw new Error('this format is not supported yet. Save it as .docx or .pdf');
      if (/^image\//.test(file.type)) throw new Error('images are not supported yet');
      let text = await file.text();
      if (ext === 'html' || ext === 'htm') text = new DOMParser().parseFromString(text, 'text/html').body.innerText;
      return { ...base, kind: 'text', text: text.trim() };
    } catch (err) {
      return { ...base, kind: 'text', on: false, err: 'Could not read: ' + err.message };
    }
  }

  async function addFiles(list) {
    const arr = [...list]; if (!arr.length) return;
    const ul = $('#fileList');
    ul.insertAdjacentHTML('afterbegin', `<li class="file" id="reading"><span class="spin"></span><div>Reading ${arr.length} file${arr.length === 1 ? '' : 's'}…</div><span></span></li>`);
    for (const f of arr) {
      if (f.size > 25 * 1024 * 1024) { files.unshift({ id: uid(), name: f.name, size: f.size, kind: 'text', on: false, err: 'File is larger than 25 MB' }); continue; }
      files.unshift(await readFile(f));
    }
    saveFiles(); renderFiles();
    const firstSheet = files.find((f) => f.kind === 'sheet' && !f.err);
    if (firstSheet && arr.some((a) => a.name === firstSheet.name)) { $('#xFile').value = firstSheet.id; showSheet(); }
  }
  $('#fileInput').onchange = (e) => { addFiles(e.target.files); e.target.value = ''; };
  const drop = $('#drop');
  ['dragenter', 'dragover'].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add('over'); }));
  ['dragleave', 'drop'].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
  drop.addEventListener('drop', (e) => addFiles(e.dataTransfer.files));
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', (e) => { e.preventDefault(); if (e.target.closest('#drop')) return; addFiles(e.dataTransfer.files); });
  $('#clearFiles').onclick = () => { if (files.length && confirm('Remove all files from the list?')) { files = []; saveFiles(); renderFiles(); } };

  // ---------- spreadsheet helpers ----------
  const toNum = (v) => { const t = String(v).replace(/[,\s$€£₹%]|Rs\.?|PKR/gi, ''); return t !== '' && !isNaN(t) ? Number(t) : null; };
  function columnStats(rows) {
    const [head, ...body] = rows; if (!head) return '';
    return head.map((h, i) => {
      const vals = body.map((r) => r[i] ?? '').filter((v) => String(v).trim() !== '');
      const nums = vals.map(toNum).filter((n) => n !== null);
      let line = `- "${h || 'Column ' + (i + 1)}": ${vals.length} filled`;
      if (nums.length && nums.length >= vals.length * 0.8) {
        const sum = nums.reduce((a, b) => a + b, 0);
        line += `, numeric: sum=${+sum.toFixed(4)}, average=${+(sum / nums.length).toFixed(4)}, min=${Math.min(...nums)}, max=${Math.max(...nums)}`;
      } else {
        const uniq = new Set(vals); line += `, ${uniq.size} distinct values`;
        if (uniq.size <= 12) line += ` (${[...uniq].slice(0, 12).map((v) => JSON.stringify(String(v).slice(0, 40))).join(', ')})`;
      }
      return line;
    }).join('\n');
  }
  const csvCell = (v) => { const s = String(v ?? ''); return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
  const toCsv = (rows) => rows.map((r) => r.map(csvCell).join(',')).join('\n');

  function sheetToContext(name, rows, budget) {
    const head = `Sheet "${name}": ${Math.max(0, rows.length - 1)} data rows, ${rows[0]?.length || 0} columns.\nColumn statistics (computed exactly, trust these numbers):\n${columnStats(rows)}\nData (CSV):\n`;
    let csv = ''; let n = 0;
    for (const r of rows) { const line = r.map(csvCell).join(',') + '\n'; if (head.length + csv.length + line.length > budget) break; csv += line; n++; }
    const note = n < rows.length ? `\n[Only the first ${n - 1} of ${rows.length - 1} rows are shown.]` : '';
    return head + csv + note;
  }

  /** Builds the file context for Chat / Write: ticked files, trimmed to the budget. */
  function filesContext(list, budget = CONTEXT_BUDGET) {
    if (!list.length) return { text: '', truncated: false };
    const per = Math.floor(budget / list.length); let truncated = false;
    const parts = list.map((f) => {
      if (f.kind === 'sheet') {
        const names = Object.keys(f.sheets); const per2 = Math.floor(per / names.length);
        return `### File: ${f.name} (spreadsheet)\n` + names.map((sn) => sheetToContext(sn, f.sheets[sn], per2)).join('\n\n');
      }
      let t = f.text || ''; if (t.length > per) { t = t.slice(0, per) + '\n[…document cut here because it is long…]'; truncated = true; }
      return `### File: ${f.name}\n${t}`;
    });
    return { text: parts.join('\n\n'), truncated };
  }
  const tickedFiles = () => files.filter((f) => f.on && !f.err);
  function updateCtx() {
    const t = tickedFiles();
    $('#chatCtx').textContent = t.length ? `📎 Using ${t.length} file${t.length === 1 ? '' : 's'}: ${t.map((f) => f.name).join(', ')}` : '📎 No files ticked: the chat answers from general knowledge.';
  }

  // =====================================================================
  // AI CALLS + LOG
  // =====================================================================
  const mode = () => $('#mode').value;
  $('#mode').value = store.get('mode', 'auto:fast');
  if (!$('#mode').value) $('#mode').value = 'auto:fast';
  $('#mode').onchange = () => store.set('mode', mode());

  let log = store.get('log', []);
  function addLog(entry) { log.unshift(entry); log = log.slice(0, 500); store.set('log', log); if ($('[data-panel=log]').classList.contains('active')) renderLog(); }
  function renderLog() {
    const ok = log.filter((l) => l.ok);
    const avg = ok.length ? ok.reduce((a, l) => a + l.secs, 0) / ok.length : 0;
    const providers = new Set(ok.map((l) => (l.via || '').split('/')[0]).filter(Boolean));
    $('#stats').innerHTML = [
      [log.length, 'Requests'],
      [log.length ? Math.round((ok.length / log.length) * 100) + '%' : '—', 'Success rate'],
      [ok.length ? avg.toFixed(1) + 's' : '—', 'Average time'],
      [providers.size || '—', 'Providers used'],
    ].map(([v, l]) => `<div class="stat"><div class="v">${v}</div><div class="l">${l}</div></div>`).join('');
    $('#logBody').innerHTML = log.length ? log.map((l) => `<tr>
      <td>${esc(new Date(l.t).toLocaleTimeString())}</td><td>${esc(l.task)}</td><td class="mono">${esc(l.mode)}</td>
      <td class="mono">${esc(l.via || '—')}</td><td>${l.secs.toFixed(1)}</td>
      <td class="${l.ok ? 'ok-t' : 'bad-t'}" title="${esc(l.err || '')}">${l.ok ? '✓ ok' : '✗ ' + esc((l.err || 'failed').slice(0, 60))}</td></tr>`).join('')
      : '<tr><td colspan="6" class="hint">No requests yet.</td></tr>';
  }
  $('#resetLog').onclick = () => { log = []; store.set('log', log); renderLog(); };
  $('#exportBtn').onclick = () => {
    const rows = [['time', 'task', 'mode', 'answered_by', 'seconds', 'ok', 'error']].concat(
      log.map((l) => [new Date(l.t).toISOString(), l.task, l.mode, l.via || '', l.secs.toFixed(2), l.ok, l.err || '']));
    download('freellm-assistant-log.csv', new Blob([toCsv(rows)], { type: 'text/csv' }));
  };

  async function errorText(res) {
    try {
      const j = await res.json();
      const m = j?.error?.message || '';
      if (res.status === 503 || /no models|no available|exhausted|All \d+ routed/i.test(m)) {
        return 'No free AI provider could answer right now. ' + (m ? `(${m.slice(0, 200)})` : '') + ' Tip: add a free Gemini or Groq key in ⚙️ Settings.';
      }
      if (res.status === 413) return 'Too much text in one request. Untick some files or use a shorter document.';
      if (res.status === 429) return 'Rate limited. Wait a minute and try again. ' + m;
      return m || `Error ${res.status}`;
    } catch { return `Error ${res.status}`; }
  }

  /** Streams a chat completion; onText(fullTextSoFar). Returns {text, via, secs}. */
  async function ai(messages, task, onText = () => {}, signal) {
    const t0 = performance.now(); const m = mode();
    try {
      const res = await fetch('/api/chat', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ model: m, messages, stream: true }), signal });
      const via = res.headers.get('x-routed-via') || '';
      if (!res.ok) throw new Error(await errorText(res));
      let text = '';
      if (!(res.headers.get('content-type') || '').includes('text/event-stream')) {
        const j = await res.json(); text = j.choices?.[0]?.message?.content || ''; onText(text);
      } else {
        const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = '';
        for (;;) {
          const { value, done } = await reader.read(); if (done) break;
          buf += dec.decode(value, { stream: true });
          let i;
          while ((i = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
            if (!line.startsWith('data:')) continue;
            const data = line.slice(5).trim(); if (data === '[DONE]') continue;
            let j; try { j = JSON.parse(data); } catch { continue; }
            if (j.error) throw new Error(j.error.message || 'Stream error');
            const d = j.choices?.[0]?.delta?.content; if (d) { text += d; onText(text); }
          }
        }
      }
      text = text.replace(/^\s*<think>[\s\S]*?<\/think>\s*/i, '');
      if (!text.trim()) throw new Error('The AI returned an empty answer. Try again or switch AI mode.');
      const secs = (performance.now() - t0) / 1000;
      addLog({ t: Date.now(), task, mode: m, via, secs, ok: true });
      return { text, via, secs };
    } catch (err) {
      if (err.name !== 'AbortError') addLog({ t: Date.now(), task, mode: m, via: '', secs: (performance.now() - t0) / 1000, ok: false, err: err.message });
      throw err;
    }
  }
  const metaLine = (r) => `answered by ${r.via || 'unknown model'} · ${r.secs.toFixed(1)}s`;
  const busy = (btn, on, label) => { btn.disabled = on; if (on) { btn.dataset.l = btn.textContent; btn.innerHTML = '<span class="spin"></span> ' + (label || 'Working…'); } else btn.textContent = btn.dataset.l || btn.textContent; };

  // ---------- output toolbars: copy / download ----------
  const outputs = {};
  function setOutput(id, text, meta) {
    outputs[id] = text;
    const bar = $(`.outbar[data-for="${id}"]`);
    bar.innerHTML = text ? `<button class="btn small" data-act="copy">📋 Copy</button>
      <button class="btn small" data-act="doc">⬇️ Word (.doc)</button>
      <button class="btn small" data-act="txt">⬇️ Text (.txt)</button>
      <span class="meta" style="margin:0">${esc(meta || '')}</span>` : '';
    $$('button', bar).forEach((b) => b.onclick = async () => {
      const t = outputs[id];
      if (b.dataset.act === 'copy') { try { await navigator.clipboard.writeText(t); b.textContent = '✓ Copied'; } catch { b.textContent = 'Copy failed'; } setTimeout(() => b.textContent = '📋 Copy', 1500); }
      if (b.dataset.act === 'txt') download(`${NAMES[id] || id}-${stamp()}.txt`, new Blob([t], { type: 'text/plain;charset=utf-8' }));
      if (b.dataset.act === 'doc') {
        const html = `<html><head><meta charset="utf-8"></head><body style="font-family:Calibri,Arial,sans-serif">${md(t)}</body></html>`;
        download(`${NAMES[id] || id}-${stamp()}.doc`, new Blob(['﻿', html], { type: 'application/msword' }));
      }
    });
  }
  const stamp = () => new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-');
  const NAMES = { wOut: 'written-text', tOut: 'translation', sOut: 'summary', xAnswer: 'data-answer' };
  function download(name, blob) {
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name;
    document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }

  // =====================================================================
  // TABS
  // =====================================================================
  $$('.tab').forEach((t) => t.onclick = () => {
    $$('.tab').forEach((x) => x.setAttribute('aria-selected', String(x === t)));
    $$('.panel').forEach((p) => p.classList.toggle('active', p.dataset.panel === t.dataset.tab));
    store.set('tab', t.dataset.tab);
    if (t.dataset.tab === 'log') renderLog();
  });
  const lastTab = $(`.tab[data-tab="${store.get('tab', 'chat')}"]`); if (lastTab) lastTab.click();

  // =====================================================================
  // CHAT
  // =====================================================================
  let history = store.get('chat', []);
  const chatlog = $('#chatlog');
  function addBubble(cls, html) {
    $('#chatEmpty')?.remove();
    const d = document.createElement('div'); d.className = 'msg ' + cls; d.innerHTML = html;
    chatlog.appendChild(d); chatlog.scrollTop = chatlog.scrollHeight; return d;
  }
  function renderChat() {
    chatlog.innerHTML = '<div class="empty" id="chatEmpty">Ask anything. Tick files on the left and the assistant will use them, for example <em>"What does this contract say about payment?"</em> or <em>"Which product sold the most?"</em></div>';
    for (const m of history) {
      if (m.role === 'user') addBubble('user', esc(m.content));
      else addBubble('ai', `<div class="md">${md(m.content)}</div>${m.meta ? `<div class="meta">${esc(m.meta)}</div>` : ''}`);
    }
  }
  renderChat();
  async function ask(q) {
    q = q.trim(); if (!q) return;
    const btn = $('#askBtn'); busy(btn, true, '');
    addBubble('user', esc(q));
    const ctx = filesContext(tickedFiles());
    const system = 'You are a helpful, accurate assistant. Answer clearly with short paragraphs or bullet points. If the user writes in a language other than English, answer in that language.' +
      (ctx.text ? '\n\nThe user has shared these files. Use them to answer, and say which file the information comes from. If the answer is not in the files, say so, then answer from general knowledge.\n\n' + ctx.text : '');
    history.push({ role: 'user', content: q });
    const bubble = addBubble('ai', '<span class="spin"></span>');
    try {
      const r = await ai([{ role: 'system', content: system }, ...history.slice(-12).map(({ role, content }) => ({ role, content }))], 'Chat',
        (t) => { bubble.innerHTML = `<div class="md">${md(t)}</div>`; chatlog.scrollTop = chatlog.scrollHeight; });
      history.push({ role: 'assistant', content: r.text, meta: metaLine(r) + (ctx.truncated ? ' · long files were shortened' : '') });
      bubble.insertAdjacentHTML('beforeend', `<div class="meta">${esc(history.at(-1).meta)}</div>`);
      store.set('chat', history.slice(-50));
    } catch (err) {
      history.pop(); bubble.className = 'msg err'; bubble.textContent = err.message;
    } finally { busy(btn, false); }
  }
  $('#askBtn').onclick = () => { const q = $('#question').value; $('#question').value = ''; ask(q); };
  $('#question').addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); $('#askBtn').click(); } });
  $$('[data-quick]').forEach((b) => b.onclick = () => ask(b.dataset.quick));
  $('#newChat').onclick = () => { history = []; store.set('chat', history); renderChat(); };

  // =====================================================================
  // WRITE
  // =====================================================================
  const LEN = { short: 'Keep it short (about 80-150 words).', medium: 'Medium length (about 250-400 words).', long: 'Long and thorough (about 700-1000 words), with headings where useful.' };
  $('#wBtn').onclick = async () => {
    const topic = $('#wTopic').value.trim();
    if (!topic) { $('#wTopic').focus(); return; }
    const btn = $('#wBtn'); busy(btn, true); setOutput('wOut', '');
    const out = $('#wOut'); out.innerHTML = '<span class="spin"></span>';
    const type = $('#wType').value; const lang = $('#wLang').value;
    const ctx = $('#wUseFiles').checked ? filesContext(tickedFiles()) : { text: '' };
    const instr = type === 'Rewrite / improve my text'
      ? `Rewrite and improve the text below so it reads well. Fix grammar and make it clear. Tone: ${$('#wTone').value}. ${LEN[$('#wLen').value]} Write it in ${lang}.\n\nTEXT:\n${topic}`
      : `Write a ${type.toLowerCase()}. Tone: ${$('#wTone').value}. ${LEN[$('#wLen').value]} Write it in ${lang}.\n\nWhat it should be about:\n${topic}`;
    try {
      const r = await ai([
        { role: 'system', content: 'You are an expert writer. Output only the finished text, ready to use (for emails include a subject line). Use markdown for headings and lists where it helps. Never invent facts, names or numbers that were not given: use placeholders like [Name] instead.' + (ctx.text ? '\n\nReference material from the user\'s files:\n' + ctx.text : '') },
        { role: 'user', content: instr },
      ], 'Write: ' + type, (t) => { out.innerHTML = md(t); });
      setOutput('wOut', r.text, metaLine(r));
    } catch (err) { out.innerHTML = `<span class="bad-t">${esc(err.message)}</span>`; }
    finally { busy(btn, false); }
  };

  // =====================================================================
  // TRANSLATE
  // =====================================================================
  function splitText(text, size) {
    const parts = []; let cur = '';
    for (const para of text.split(/\n{2,}/)) {
      if ((cur + '\n\n' + para).length > size && cur) { parts.push(cur); cur = ''; }
      if (para.length > size) { for (let i = 0; i < para.length; i += size) parts.push(para.slice(i, i + size)); continue; }
      cur = cur ? cur + '\n\n' + para : para;
    }
    if (cur) parts.push(cur);
    return parts;
  }
  function docText(f) {
    if (f.kind === 'sheet') return Object.entries(f.sheets).map(([sn, rows]) => `Sheet ${sn}:\n` + toCsv(rows)).join('\n\n');
    return f.text || '';
  }
  $('#tSource').onchange = () => { $('#tText').classList.toggle('hidden', $('#tSource').value !== 'text'); };
  $('#tBtn').onclick = async () => {
    const src = $('#tSource').value;
    const f = files.find((x) => x.id === src);
    const text = src === 'text' ? $('#tText').value.trim() : f ? docText(f) : '';
    if (!text) { $('#tText').focus(); return; }
    const lang = $('#tLang').value;
    const parts = splitText(text, T_CHUNK);
    const btn = $('#tBtn'); busy(btn, true); setOutput('tOut', '');
    const out = $('#tOut'); out.innerHTML = '<span class="spin"></span>';
    let done = ''; let last;
    try {
      for (let i = 0; i < parts.length; i++) {
        $('#tProg').textContent = parts.length > 1 ? `Translating part ${i + 1} of ${parts.length}…` : '';
        last = await ai([
          { role: 'system', content: `You are a professional translator. Translate the user's text into ${lang}. Keep the meaning, tone, formatting, numbers and names. Output only the translation, nothing else.` },
          { role: 'user', content: parts[i] },
        ], `Translate → ${lang}` + (parts.length > 1 ? ` (${i + 1}/${parts.length})` : ''), (t) => { out.innerHTML = md(done + t); });
        done += last.text.trim() + '\n\n';
      }
      $('#tProg').textContent = '';
      setOutput('tOut', done.trim(), metaLine(last) + (parts.length > 1 ? ` · ${parts.length} parts` : ''));
    } catch (err) {
      $('#tProg').textContent = '';
      out.innerHTML = (done ? md(done) : '') + `<p class="bad-t">${esc(err.message)}</p>`;
      if (done) setOutput('tOut', done.trim(), 'stopped early');
    } finally { busy(btn, false); }
  };

  // =====================================================================
  // SUMMARISE
  // =====================================================================
  const STYLE = {
    bullets: 'Summarise as 6-12 clear bullet points covering the key information. Start with a one-line overview.',
    exec: 'Write an executive summary: a short overview paragraph, then key findings, risks and recommendations as bullets.',
    detailed: 'Write a detailed summary organised by the document\'s main sections, with headings.',
    actions: 'List the decisions, action items (who/what/when if stated), deadlines and open questions.',
    simple: 'Explain what this document says in simple, everyday words that anyone can understand.',
  };
  $('#sBtn').onclick = async () => {
    const f = files.find((x) => x.id === $('#sSource').value);
    if (!f) { alert('Upload a document on the left first.'); return; }
    const text = f.kind === 'sheet' ? filesContext([f], 30000).text : f.text;
    const lang = $('#sLang').value; const style = STYLE[$('#sStyle').value];
    const btn = $('#sBtn'); busy(btn, true); setOutput('sOut', '');
    const out = $('#sOut'); out.innerHTML = '<span class="spin"></span>';
    const sys = { role: 'system', content: 'You are an expert analyst who writes accurate, well-organised summaries in markdown. Only use information from the document.' };
    try {
      let material = text;
      const parts = f.kind === 'sheet' ? [text] : splitText(text, CHUNK);
      if (parts.length > 1) {
        const notes = [];
        for (let i = 0; i < parts.length; i++) {
          $('#sProg').textContent = `Reading part ${i + 1} of ${parts.length}…`;
          const r = await ai([sys, { role: 'user', content: `This is part ${i + 1} of ${parts.length} of the document "${f.name}". Write detailed notes of all key points, facts, numbers and decisions in this part.\n\n${parts[i]}` }], `Summarise part ${i + 1}/${parts.length}`);
          notes.push(`Notes on part ${i + 1}:\n${r.text}`);
        }
        material = notes.join('\n\n');
        $('#sProg').textContent = 'Combining the parts…';
      }
      const r = await ai([sys, { role: 'user', content: `${style} Write it in ${lang}.\n\nDOCUMENT "${f.name}"${parts.length > 1 ? ' (notes from each part)' : ''}:\n${material}` }], 'Summarise', (t) => { out.innerHTML = md(t); });
      $('#sProg').textContent = '';
      setOutput('sOut', r.text, metaLine(r) + (parts.length > 1 ? ` · read in ${parts.length} parts` : ''));
    } catch (err) { $('#sProg').textContent = ''; out.innerHTML = `<span class="bad-t">${esc(err.message)}</span>`; }
    finally { busy(btn, false); }
  };

  // =====================================================================
  // EXCEL / DATA
  // =====================================================================
  function refreshSelectors() {
    const tf = textFiles();
    const keepS = $('#sSource').value, keepT = $('#tSource').value, keepX = $('#xFile').value;
    $('#sSource').innerHTML = tf.length ? tf.map((f) => `<option value="${f.id}">${esc(f.name)}</option>`).join('') : '<option value="">(no files yet)</option>';
    if (tf.some((f) => f.id === keepS)) $('#sSource').value = keepS;
    $('#tSource').innerHTML = '<option value="text">Text I paste below</option>' + tf.map((f) => `<option value="${f.id}">File: ${esc(f.name)}</option>`).join('');
    $('#tSource').value = tf.some((f) => f.id === keepT) ? keepT : 'text';
    $('#tText').classList.toggle('hidden', $('#tSource').value !== 'text');
    const sf = sheetFiles();
    $('#xFile').innerHTML = sf.length ? sf.map((f) => `<option value="${f.id}">${esc(f.name)}</option>`).join('') : '<option value="">(upload an Excel or CSV file)</option>';
    if (sf.some((f) => f.id === keepX)) $('#xFile').value = keepX;
    showSheet();
  }
  const curSheetFile = () => files.find((f) => f.id === $('#xFile').value && f.kind === 'sheet');
  function curRows() { const f = curSheetFile(); return f ? f.sheets[$('#xSheet').value] || null : null; }
  function tableHtml(rows, limit = 100) {
    if (!rows?.length) return '';
    const [head, ...body] = rows; const width = Math.max(...rows.slice(0, limit + 1).map((r) => r.length));
    const cells = (r, tag) => Array.from({ length: width }, (_, i) => `<${tag} title="${esc(r[i] ?? '')}">${esc(r[i] ?? '')}</${tag}>`).join('');
    return `<thead><tr><th class="n">#</th>${cells(head, 'th')}</tr></thead><tbody>` +
      body.slice(0, limit).map((r, i) => `<tr><td class="n">${i + 1}</td>${cells(r, 'td')}</tr>`).join('') + '</tbody>';
  }
  let lastSheetKey = '';
  function showSheet() {
    const f = curSheetFile();
    const names = f ? Object.keys(f.sheets) : [];
    const keep = $('#xSheet').value;
    $('#xSheet').innerHTML = names.map((n) => `<option>${esc(n)}</option>`).join('');
    if (names.includes(keep)) $('#xSheet').value = keep;
    const rows = curRows();
    $('#xPreviewWrap').classList.toggle('hidden', !rows);
    if (!rows) { $('#xInfo').textContent = 'Upload an Excel or CSV file on the left to start (or click "Add sample files").'; return; }
    $('#xInfo').textContent = `${(rows.length - 1).toLocaleString()} rows × ${rows[0].length} columns` + (rows.length > 101 ? ' · showing the first 100 rows' : '');
    $('#xPreview').innerHTML = tableHtml(rows);
    const key = f.id + '|' + $('#xSheet').value;
    if (key !== lastSheetKey) { lastSheetKey = key; $('#xResultWrap').classList.add('hidden'); $('#xResultBar').classList.add('hidden'); $('#xProg').textContent = ''; }
  }
  $('#xFile').onchange = showSheet; $('#xSheet').onchange = showSheet;

  $('#xAskBtn').onclick = async () => {
    const rows = curRows(); const q = $('#xQ').value.trim();
    if (!rows) { alert('Upload an Excel or CSV file first.'); return; }
    if (!q) { $('#xQ').focus(); return; }
    const btn = $('#xAskBtn'); busy(btn, true, ''); setOutput('xAnswer', '');
    const out = $('#xAnswer'); out.classList.remove('hidden'); out.innerHTML = '<span class="spin"></span>';
    try {
      const r = await ai([
        { role: 'system', content: 'You are a careful data analyst. Answer questions about the spreadsheet below. Use the provided column statistics for totals and averages instead of adding numbers yourself. If only part of the data is shown, say so. Use markdown tables when helpful.\n\n' + sheetToContext($('#xSheet').value, rows, 30000) },
        { role: 'user', content: q },
      ], 'Excel question', (t) => { out.innerHTML = md(t); });
      setOutput('xAnswer', r.text, metaLine(r));
    } catch (err) { out.innerHTML = `<span class="bad-t">${esc(err.message)}</span>`; }
    finally { busy(btn, false); }
  };
  $('#xQ').addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); $('#xAskBtn').click(); } });
  $$('[data-xq]').forEach((b) => b.onclick = () => { $('#xEdit').value = b.dataset.xq; $('#xEdit').focus(); });

  async function parseCsvReply(text) {
    const XLSX = await lib('xlsx');
    const m = text.match(/```(?:csv)?\s*\n([\s\S]*?)```/i);
    const csv = (m ? m[1] : text).trim();
    const wb = XLSX.read(csv, { type: 'string', raw: true });
    return XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '', raw: true, blankrows: false }).map((r) => r.map((c) => String(c ?? '')));
  }

  let xResult = null;
  $('#xEditBtn').onclick = async () => {
    const rows = curRows(); const instr = $('#xEdit').value.trim();
    if (!rows) { alert('Upload an Excel or CSV file first.'); return; }
    if (!instr) { $('#xEdit').focus(); return; }
    const [head, ...body] = rows;
    if (body.length > MAX_EDIT_ROWS && !confirm(`This sheet has ${body.length} rows. Only the first ${MAX_EDIT_ROWS} will be processed (about ${Math.ceil(MAX_EDIT_ROWS / ROW_BATCH)} AI requests). Continue?`)) return;
    const work = body.slice(0, MAX_EDIT_ROWS);
    const batches = []; for (let i = 0; i < work.length; i += ROW_BATCH) batches.push(work.slice(i, i + ROW_BATCH));
    const btn = $('#xEditBtn'); busy(btn, true);
    $('#xResultBar').classList.add('hidden');
    let newHead = null; const outRows = []; let problems = 0;
    try {
      for (let b = 0; b < batches.length; b++) {
        $('#xProg').innerHTML = `<span class="spin"></span> Processing rows ${b * ROW_BATCH + 1}–${b * ROW_BATCH + batches[b].length} of ${work.length} (batch ${b + 1} of ${batches.length})…`;
        const input = toCsv([head, ...batches[b]]);
        const messages = [
          { role: 'system', content: 'You edit spreadsheet data. You receive CSV with a header row. Apply the instruction to every row and reply with ONLY the complete resulting CSV (header row first) inside one ```csv code block. Keep exactly the same number of data rows, in the same order. Use the same header for every batch. Quote cells that contain commas.' },
          { role: 'user', content: `Instruction: ${instr}\n\nCSV (${batches[b].length} data rows):\n\`\`\`csv\n${input}\n\`\`\`` },
        ];
        let got = null;
        for (let attempt = 0; attempt < 2 && !got; attempt++) {
          const r = await ai(messages, `Excel edit ${b + 1}/${batches.length}` + (attempt ? ' (retry)' : ''));
          const parsed = await parseCsvReply(r.text);
          if (parsed.length - 1 === batches[b].length) got = parsed;
          else if (attempt === 1 && parsed.length > 1) { got = parsed; problems++; }
        }
        if (!got) throw new Error(`Batch ${b + 1} did not come back as a table. Try again or pick "Smartest available" mode.`);
        if (!newHead) newHead = got[0];
        outRows.push(...got.slice(1));
        xResult = [newHead, ...outRows];
        $('#xResultWrap').classList.remove('hidden'); $('#xResult').innerHTML = tableHtml(xResult);
      }
      $('#xProg').innerHTML = `<span class="ok-t">✓ Done: ${outRows.length} rows processed.</span>` +
        (problems ? ` <span class="warn-t">${problems} batch(es) came back with a different number of rows; please check the result.</span>` : '') +
        (body.length > MAX_EDIT_ROWS ? ` <span class="warn-t">Only the first ${MAX_EDIT_ROWS} rows were processed.</span>` : '');
      $('#xResultBar').classList.remove('hidden');
    } catch (err) {
      $('#xProg').innerHTML = `<span class="bad-t">${esc(err.message)}</span>` + (outRows.length ? ` <span class="hint">${outRows.length} rows finished; you can still download them.</span>` : '');
      if (outRows.length) $('#xResultBar').classList.remove('hidden');
    } finally { busy(btn, false); }
  };
  const baseName = () => (curSheetFile()?.name || 'data').replace(/\.[^.]+$/, '');
  $('#xDlXlsx').onclick = async () => {
    const XLSX = await lib('xlsx');
    const typed = xResult.map((r, i) => i === 0 ? r : r.map((c) => (/^-?\d+(\.\d+)?$/.test(c.trim()) && c.trim().length < 16 ? Number(c) : c)));
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(typed), ($('#xSheet').value || 'Sheet1').slice(0, 31));
    XLSX.writeFile(wb, `${baseName()}-edited.xlsx`);
  };
  $('#xDlCsv').onclick = () => download(`${baseName()}-edited.csv`, new Blob(['﻿' + toCsv(xResult)], { type: 'text/csv;charset=utf-8' }));
  $('#xKeep').onclick = () => {
    files.unshift({ id: uid(), name: `${baseName()}-edited.xlsx`, size: toCsv(xResult).length, kind: 'sheet', sheets: { [$('#xSheet').value || 'Sheet1']: xResult }, on: true });
    saveFiles(); renderFiles(); $('#xFile').value = files[0].id; showSheet();
  };

  // =====================================================================
  // SAMPLE FILES
  // =====================================================================
  $('#sampleBtn').onclick = () => {
    const sales = [['Date', 'Region', 'Product', 'Units', 'Revenue']];
    const regions = ['North', 'South', 'East', 'West']; const products = ['Water filter', 'Solar lamp', 'School kit', 'First-aid box'];
    for (let i = 0; i < 24; i++) {
      const units = 5 + ((i * 37) % 40);
      sales.push([`2026-${String(1 + (i % 6)).padStart(2, '0')}-${String(3 + i).padStart(2, '0')}`, regions[i % 4], products[(i * 3) % 4], String(units), String(units * [25, 18, 12, 30][(i * 3) % 4])]);
    }
    const memo = `Community Project Update — October

Summary: The water-filter programme reached 1,240 households across four districts this quarter, 18% above target. Volunteer numbers grew from 45 to 72.

Challenges: Delivery to the East district was delayed by two weeks because of road repairs. Solar lamp stock is low and must be re-ordered before 15 November.

Decisions: The board approved a budget of $12,000 for the winter school-kit drive. Sara Khan will coordinate volunteers; Ahmed Ali will handle suppliers.

Next steps:
1. Re-order 300 solar lamps by 15 November (Ahmed).
2. Recruit 20 more volunteers for the school-kit drive (Sara).
3. Publish the quarterly report on the website by 30 November.`;
    files.unshift({ id: uid(), name: 'project-update.txt', size: memo.length, kind: 'text', text: memo, on: true });
    files.unshift({ id: uid(), name: 'sales-2026.xlsx', size: toCsv(sales).length, kind: 'sheet', sheets: { Sales: sales }, on: true });
    saveFiles(); renderFiles(); $('#xFile').value = files[0].id; showSheet();
  };

  // =====================================================================
  // STATUS + SETTINGS
  // =====================================================================
  const PROVIDERS = [
    ['google', 'Google Gemini', 'https://aistudio.google.com/apikey'],
    ['groq', 'Groq (very fast)', 'https://console.groq.com/keys'],
    ['cerebras', 'Cerebras (very fast)', 'https://cloud.cerebras.ai/'],
    ['openrouter', 'OpenRouter', 'https://openrouter.ai/keys'],
    ['mistral', 'Mistral', 'https://console.mistral.ai/api-keys'],
  ];
  $('#keyRows').innerHTML = PROVIDERS.map(([id, name, url]) => `
    <div class="keyrow"><div><b>${name}</b><br><a href="${url}" target="_blank" rel="noopener" style="font-size:12px">get free key ↗</a></div>
      <input type="password" placeholder="paste key" data-key="${id}" autocomplete="off">
      <button class="btn small" data-save="${id}">Add</button></div>`).join('');
  $$('[data-save]').forEach((b) => b.onclick = async () => {
    const platform = b.dataset.save; const input = $(`[data-key="${platform}"]`); const msg = $('#keyMsg');
    if (!input.value.trim()) return;
    b.disabled = true; msg.textContent = 'Adding key…';
    try {
      const res = await fetch('/api/keys', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ platform, key: input.value.trim() }) });
      const j = await res.json();
      if (!res.ok) throw new Error(j?.error?.message || 'failed');
      input.value = ''; msg.innerHTML = `<span class="ok-t">✓ Added ${esc(platform)} key${j.modelsAvailable ? ` (${j.modelsAvailable} models unlocked)` : ''}.</span>`;
      refreshStatus();
    } catch (err) { msg.innerHTML = `<span class="bad-t">${esc(err.message)}</span>`; }
    finally { b.disabled = false; }
  });
  $('#settingsBtn').onclick = () => $('#settings').showModal();
  $('#closeSettings').onclick = () => $('#settings').close();

  async function refreshStatus() {
    const pill = $('#status'), txt = $('#statusText'), warn = $('#noModels');
    try {
      const s = await (await fetch('/api/status')).json();
      $('#dashLink').href = s.dashboardUrl; $('#dashEmail').textContent = s.dashboardEmail || '—'; $('#dashPass').textContent = s.dashboardPassword || '—';
      if (!s.freellmapi) { pill.className = 'pill bad'; txt.textContent = 'FreeLLMAPI not running'; warn.classList.remove('hidden'); warn.textContent = 'The FreeLLMAPI router is not running. Double-click "FreeLLM Assistant" on your Desktop (or run ~/FreeLLM-Assistant/start.sh).'; return; }
      if (!s.models) {
        pill.className = 'pill warn'; txt.textContent = 'No AI models yet';
        warn.classList.remove('hidden');
        warn.innerHTML = 'Connected to FreeLLMAPI, but no free AI models are active yet. The no-key providers usually appear within a minute of first start. To get going right away, <a href="#" id="openSet">add a free Gemini or Groq key in Settings</a>.';
        $('#openSet').onclick = (e) => { e.preventDefault(); $('#settings').showModal(); };
      } else {
        pill.className = 'pill ok'; txt.textContent = `Connected · ${s.models} free model${s.models === 1 ? '' : 's'}`;
        pill.title = 'Available now: ' + (s.modelNames || []).join(', ');
        warn.classList.add('hidden');
      }
    } catch { pill.className = 'pill bad'; txt.textContent = 'App server offline'; }
  }

  renderFiles();
  renderLog();
  refreshStatus(); setInterval(refreshStatus, 20000);
})();
</script>
</body>
</html>
ASSISTANT_EMBED_EOF
cat > "$HOME_DIR/app/package.json" <<'ASSISTANT_EMBED_EOF'
{
  "name": "freellm-assistant-app",
  "private": true,
  "description": "Browser file readers served locally by app/server.mjs",
  "dependencies": {
    "mammoth": "1.13.0",
    "pdfjs-dist": "3.11.174",
    "xlsx": "0.18.5"
  }
}
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
