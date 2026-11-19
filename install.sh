#!/usr/bin/env bash
# Course AI Study Buddy — one-command installer for macOS (also works on Linux).
#
#   curl -fsSL https://raw.githubusercontent.com/khleeq92-netizen/FreeLLM/claude/lucid-sagan-282tpm/install.sh | bash
#
# What it does (everything lives in ~/CourseAI, no sudo, nothing system-wide):
#   1. Uses your Node.js 20-24 if you have it, otherwise downloads Node 22 (checksum-verified).
#   2. Downloads and builds FreeLLMAPI (the free-LLM router) from GitHub.
#   3. Installs the Study Buddy web app.
#   4. Creates start/stop scripts and a "Course AI" shortcut on your Desktop (macOS).
#   5. Starts everything and opens http://127.0.0.1:3100 in your browser.
#
# Re-running it is safe: it updates FreeLLMAPI and the app, and keeps your data, keys and password.
#
# Optional settings (put them before "bash" or export them first):
#   COURSEAI_HOME=~/CourseAI       install folder
#   COURSEAI_PORT=3100             Study Buddy port
#   FREELLMAPI_PORT=3001           FreeLLMAPI router + dashboard port
#   FREELLMAPI_REF=main            FreeLLMAPI branch or tag to install
#   GEMINI_API_KEY=... GROQ_API_KEY=... CEREBRAS_API_KEY=... OPENROUTER_API_KEY=... MISTRAL_API_KEY=...
#                                  free provider keys to add on first start
#   COURSEAI_NO_OPEN=1             do not open the browser
#   COURSEAI_NO_START=1            install only, do not start

set -euo pipefail

COURSEAI_HOME="${COURSEAI_HOME:-$HOME/CourseAI}"
APP_PORT="${COURSEAI_PORT:-3100}"
FL_PORT="${FREELLMAPI_PORT:-3001}"
FL_REF="${FREELLMAPI_REF:-main}"
FL_REPO="tashfeenahmed/freellmapi"
NODE_LINE="v22"

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
bold "📚 Course AI Study Buddy installer"
info "Install folder: $COURSEAI_HOME"
mkdir -p "$COURSEAI_HOME"/{config,data,logs,run,runtime,app/public}
chmod 700 "$COURSEAI_HOME/config" "$COURSEAI_HOME/data"

# Stop a previous run before replacing files.
if [ -x "$COURSEAI_HOME/stop.sh" ]; then "$COURSEAI_HOME/stop.sh" >/dev/null 2>&1 || true; fi

# ---------------------------------------------------------------------------
step "1/5  Node.js"
# ---------------------------------------------------------------------------
node_ok() {
  "$1" -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit((a>20||(a===20&&b>=18))&&a<25?0:1)' 2>/dev/null
}
NODE_BIN=""
if [ -x "$COURSEAI_HOME/runtime/node/bin/node" ] && node_ok "$COURSEAI_HOME/runtime/node/bin/node"; then
  NODE_BIN="$COURSEAI_HOME/runtime/node/bin/node"
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
  rm -rf "$COURSEAI_HOME/runtime/node"; mkdir -p "$COURSEAI_HOME/runtime/node"
  tar -xzf "$TMPD/$TARBALL" -C "$COURSEAI_HOME/runtime/node" --strip-components=1
  NODE_BIN="$COURSEAI_HOME/runtime/node/bin/node"
fi
NODE_DIR="$(dirname "$NODE_BIN")"
export PATH="$NODE_DIR:$PATH"
NPM_BIN="$NODE_DIR/npm"; [ -x "$NPM_BIN" ] || NPM_BIN="$(command -v npm)"
info "Using Node $("$NODE_BIN" -v) at $NODE_BIN"

# ---------------------------------------------------------------------------
step "2/5  FreeLLMAPI router (download + build, takes 2-5 minutes the first time)"
# ---------------------------------------------------------------------------
FL_DIR="$COURSEAI_HOME/freellmapi"
FL_NEW="$COURSEAI_HOME/freellmapi.new"
rm -rf "$FL_NEW"; mkdir -p "$FL_NEW"
if [ -n "${FREELLMAPI_SRC_DIR:-}" ]; then
  info "Copying FreeLLMAPI from $FREELLMAPI_SRC_DIR"
  (cd "$FREELLMAPI_SRC_DIR" && tar --exclude=node_modules --exclude=.git -cf - .) | (cd "$FL_NEW" && tar -xf -)
else
  info "Downloading github.com/$FL_REPO ($FL_REF)…"
  curl -fsSL "https://codeload.github.com/$FL_REPO/tar.gz/$FL_REF" | tar -xzf - -C "$FL_NEW" --strip-components=1 \
    || die "Could not download FreeLLMAPI. Check your internet connection."
fi
LOG_BUILD="$COURSEAI_HOME/logs/build.log"
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
step "3/5  Study Buddy app"
# ---------------------------------------------------------------------------
cat > "$COURSEAI_HOME/app/server.mjs" <<'COURSEAI_EMBED_EOF'
// Course AI Study Buddy — local web app that talks to a FreeLLMAPI router.
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
const PORT = Number(process.env.COURSEAI_PORT || 3100);
const HOST = '127.0.0.1';
const FREELLMAPI_URL = (process.env.FREELLMAPI_URL || 'http://127.0.0.1:3001').replace(/\/+$/, '');
const FREELLMAPI_DIR = process.env.FREELLMAPI_DIR || '';
const DB_PATH = process.env.FREEAPI_DB_PATH || '';
const ADMIN_EMAIL = process.env.COURSEAI_ADMIN_EMAIL || '';
const ADMIN_PASSWORD = process.env.COURSEAI_ADMIN_PASSWORD || '';
const MAX_BODY = 8 * 1024 * 1024;

const INDEX_HTML = path.join(HERE, 'public', 'index.html');

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
    console.error('[courseai] could not read the unified key:', err.message);
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
    const r = await dashboardFetch('/api/keys', { method: 'POST', body: JSON.stringify({ platform, key, label: 'added from Study Buddy' }) });
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
  console.log(`[courseai] Study Buddy running at http://${HOST}:${PORT} (FreeLLMAPI: ${FREELLMAPI_URL})`);
  // Best effort: make sure the no-key providers are on, so it works with zero signups.
  setTimeout(() => { enableFreeProviders().then((e) => e.length && console.log(`[courseai] enabled free no-key providers: ${e.join(', ')}`)); }, 1500);
});
COURSEAI_EMBED_EOF
cat > "$COURSEAI_HOME/app/public/index.html" <<'COURSEAI_EMBED_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Course AI Study Buddy</title>
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

  header { display: flex; align-items: center; gap: 12px; padding: 14px 20px; border-bottom: 1px solid var(--border); background: var(--panel); position: sticky; top: 0; z-index: 5; flex-wrap: wrap; }
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

  main { display: grid; grid-template-columns: minmax(280px, 400px) 1fr; gap: 18px; padding: 18px 20px 40px; max-width: 1400px; margin: 0 auto; }
  @media (max-width: 860px) { main { grid-template-columns: 1fr; padding: 14px 16px 40px; } }
  .card { background: var(--panel); border: 1px solid var(--border); border-radius: var(--radius); box-shadow: var(--shadow); padding: 16px; min-width: 0; }
  .card h2 { font-size: 15px; margin: 0 0 4px; }
  .hint { color: var(--muted); font-size: 13px; margin: 0 0 10px; }
  textarea { width: 100%; border: 1px solid var(--border); background: var(--panel-2); border-radius: 9px; padding: 10px; resize: vertical; }
  textarea:focus, input:focus, select:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
  #material { min-height: 320px; font-size: 14px; }
  .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .row.between { justify-content: space-between; }
  .counter { color: var(--muted); font-size: 12px; }
  select, input[type=text], input[type=password], input[type=number] { border: 1px solid var(--border); background: var(--panel-2); border-radius: 9px; padding: 7px 10px; }

  .tabs { display: flex; gap: 4px; border-bottom: 1px solid var(--border); margin: -4px -4px 14px; padding: 0 4px; overflow-x: auto; }
  .tab { border: none; background: none; padding: 9px 12px; cursor: pointer; color: var(--muted); border-bottom: 2px solid transparent; white-space: nowrap; }
  .tab[aria-selected="true"] { color: var(--text); border-bottom-color: var(--accent); font-weight: 600; }
  .panel { display: none; } .panel.active { display: block; }

  .chatlog { display: flex; flex-direction: column; gap: 12px; min-height: 240px; max-height: 58vh; overflow-y: auto; padding: 4px 2px 8px; }
  .msg { max-width: 92%; padding: 10px 13px; border-radius: 12px; overflow-wrap: anywhere; }
  .msg.user { align-self: flex-end; background: var(--accent); color: var(--accent-text); white-space: pre-wrap; }
  .msg.ai { align-self: flex-start; background: var(--panel-2); border: 1px solid var(--border); }
  .msg.err { align-self: flex-start; background: var(--bad-soft); color: var(--bad); }
  .meta { font-size: 12px; color: var(--muted); margin-top: 6px; font-family: var(--mono); }
  .empty { color: var(--muted); text-align: center; padding: 40px 10px; }
  .composer { display: flex; gap: 8px; margin-top: 10px; }
  .composer textarea { min-height: 46px; height: 46px; }

  .md h1, .md h2, .md h3 { font-size: 1.05em; margin: .8em 0 .3em; }
  .md p { margin: .4em 0; } .md ul, .md ol { margin: .3em 0; padding-left: 1.3em; }
  .md code { font-family: var(--mono); font-size: .9em; background: var(--panel); border: 1px solid var(--border); padding: 0 4px; border-radius: 4px; }
  .md pre { background: var(--panel); border: 1px solid var(--border); padding: 10px; border-radius: 8px; overflow-x: auto; }
  .md pre code { border: none; padding: 0; }

  .output { background: var(--panel-2); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; margin-top: 12px; min-height: 60px; }

  .quiz-q { border: 1px solid var(--border); border-radius: 10px; padding: 12px; margin-top: 10px; background: var(--panel-2); }
  .quiz-q .q { font-weight: 600; margin-bottom: 8px; }
  .opt { display: block; width: 100%; text-align: left; margin: 5px 0; padding: 8px 10px; border-radius: 8px; border: 1px solid var(--border); background: var(--panel); cursor: pointer; }
  .opt:hover:not(:disabled) { border-color: var(--accent); }
  .opt.right { background: var(--ok-soft); border-color: var(--ok); color: var(--ok); }
  .opt.wrong { background: var(--bad-soft); border-color: var(--bad); color: var(--bad); }
  .explain { font-size: 13px; color: var(--muted); margin-top: 6px; }
  .score { font-weight: 600; margin-top: 12px; }

  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; margin-top: 12px; }
  .flash { min-height: 140px; border-radius: 12px; border: 1px solid var(--border); background: var(--panel-2); padding: 14px; cursor: pointer; display: flex; flex-direction: column; justify-content: center; text-align: center; transition: background .15s; }
  .flash.flipped { background: var(--accent-soft); }
  .flash .side { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); margin-bottom: 6px; }

  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; margin-bottom: 14px; }
  .stat { background: var(--panel-2); border: 1px solid var(--border); border-radius: 10px; padding: 10px 12px; }
  .stat .v { font-size: 22px; font-weight: 700; }
  .stat .l { font-size: 12px; color: var(--muted); }
  .tablewrap { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--border); white-space: nowrap; }
  th { color: var(--muted); font-weight: 600; }
  td.mono { font-family: var(--mono); }
  .ok-t { color: var(--ok); } .bad-t { color: var(--bad); }

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
    <h1>📚 Course AI Study Buddy</h1>
    <div class="sub">Free AI tutor powered by FreeLLMAPI. It runs on your Mac and uses free AI providers.</div>
  </div>
  <div class="spacer"></div>
  <span id="status" class="pill"><span class="dot"></span><span id="statusText">Checking…</span></span>
  <label class="row" style="gap:6px;font-size:13px;color:var(--muted)">AI mode
    <select id="mode" title="How the router chooses a model">
      <option value="auto">Auto (balanced)</option>
      <option value="auto:fast">Fast</option>
      <option value="auto:smart">Smartest available</option>
      <option value="auto:reliable">Most reliable</option>
      <option value="fusion">Fusion (several AIs + judge, slow)</option>
    </select>
  </label>
  <button class="btn" id="settingsBtn">⚙️ Settings</button>
</header>

<main>
  <section class="card">
    <div class="row between"><h2>1. Course material</h2><span class="counter" id="count">0 characters</span></div>
    <p class="hint">Paste lecture notes or a chapter, or load a .txt, .md or .pdf file. Every tool on the right uses this text.</p>
    <textarea id="material" placeholder="Paste your course notes here…"></textarea>
    <div class="row" style="margin-top:10px">
      <label class="btn small" for="file">📄 Load file</label>
      <input type="file" id="file" accept=".txt,.md,.markdown,.csv,.pdf,text/plain,application/pdf" class="hidden">
      <button class="btn small" id="sampleBtn">✨ Try a sample lesson</button>
      <button class="btn small" id="clearBtn">Clear</button>
    </div>
    <p class="hint" id="fileInfo" style="margin-top:8px"></p>
  </section>

  <section class="card">
    <div class="tabs" role="tablist">
      <button class="tab" role="tab" data-tab="chat" aria-selected="true">💬 Ask the tutor</button>
      <button class="tab" role="tab" data-tab="summary" aria-selected="false">📝 Summary</button>
      <button class="tab" role="tab" data-tab="quiz" aria-selected="false">❓ Quiz</button>
      <button class="tab" role="tab" data-tab="cards" aria-selected="false">🃏 Flashcards</button>
      <button class="tab" role="tab" data-tab="log" aria-selected="false">📊 Test log</button>
    </div>

    <div id="noModels" class="notice warn hidden"></div>

    <div class="panel active" data-panel="chat">
      <div class="chatlog" id="chatlog"><div class="empty" id="chatEmpty">Ask anything about your course material, for example <em>"Explain this like I'm new to the topic"</em> or <em>"Give me a real-life example"</em>.</div></div>
      <div class="composer">
        <textarea id="question" placeholder="Type your question… (Enter to send, Shift+Enter for a new line)"></textarea>
        <button class="btn primary" id="askBtn">Send</button>
      </div>
      <div class="row" style="margin-top:8px">
        <button class="btn small" data-quick="Explain the main idea of this material in simple words, like I'm a beginner.">Explain simply</button>
        <button class="btn small" data-quick="Give me 3 real-life examples that illustrate this material.">Real-life examples</button>
        <button class="btn small" data-quick="What are the most common mistakes or misconceptions students have about this topic?">Common mistakes</button>
        <button class="btn small" id="newChat">New chat</button>
      </div>
    </div>

    <div class="panel" data-panel="summary">
      <div class="row">
        <select id="sumStyle">
          <option value="bullet">Key points (bullets)</option>
          <option value="short">Short paragraph</option>
          <option value="exam">Exam revision sheet</option>
          <option value="eli5">Explain like I'm 12</option>
        </select>
        <button class="btn primary" id="sumBtn">Summarise</button>
      </div>
      <div class="output md" id="sumOut"><span class="hint">Your summary will appear here.</span></div>
      <div class="meta" id="sumMeta"></div>
    </div>

    <div class="panel" data-panel="quiz">
      <div class="row">
        <label class="row" style="gap:6px">Questions <input type="number" id="quizN" min="3" max="10" value="5" style="width:70px"></label>
        <select id="quizLevel"><option>easy</option><option selected>medium</option><option>hard</option></select>
        <button class="btn primary" id="quizBtn">Make quiz</button>
      </div>
      <div id="quizOut"></div>
      <div class="meta" id="quizMeta"></div>
    </div>

    <div class="panel" data-panel="cards">
      <div class="row">
        <label class="row" style="gap:6px">Cards <input type="number" id="cardN" min="4" max="16" value="8" style="width:70px"></label>
        <button class="btn primary" id="cardBtn">Make flashcards</button>
        <span class="hint" style="margin:0">Click a card to flip it.</span>
      </div>
      <div class="cards" id="cardOut"></div>
      <div class="meta" id="cardMeta"></div>
    </div>

    <div class="panel" data-panel="log">
      <p class="hint">Every AI request is logged here so you can judge whether the free API is good enough for the course: success rate, speed, and which provider answered.</p>
      <div class="stats" id="stats"></div>
      <div class="row" style="margin-bottom:10px">
        <button class="btn small" id="exportBtn">⬇️ Export CSV</button>
        <button class="btn small" id="resetLog">Clear log</button>
      </div>
      <div class="tablewrap"><table>
        <thead><tr><th>Time</th><th>Task</th><th>Mode</th><th>Answered by</th><th>Seconds</th><th>Result</th></tr></thead>
        <tbody id="logBody"></tbody>
      </table></div>
    </div>
  </section>
</main>

<dialog id="settings">
  <div class="dlg">
    <h3>Settings</h3>
    <div class="notice info">Works without any signup: FreeLLMAPI turns on its no-key providers automatically. <b>For better and faster answers</b>, add one or more <b>free</b> keys below. Each takes about a minute to get and needs no credit card.</div>
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
  const MAX_CHARS = 15000;

  // ---------- safe storage (works even when the browser blocks it) ----------
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
  };

  // ---------- theme ----------
  const applyTheme = (t) => { if (t) document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme; };
  applyTheme(store.get('theme', ''));
  $('#theme').value = store.get('theme', '');
  $('#theme').onchange = (e) => { store.set('theme', e.target.value); applyTheme(e.target.value); };

  // ---------- material ----------
  const material = $('#material');
  material.value = store.get('material', '');
  const updateCount = () => {
    const n = material.value.length;
    $('#count').textContent = `${n.toLocaleString()} characters` + (n > MAX_CHARS ? ` (only the first ${MAX_CHARS.toLocaleString()} are sent)` : '');
  };
  material.addEventListener('input', () => { store.set('material', material.value); updateCount(); });
  updateCount();
  const getMaterial = () => material.value.trim().slice(0, MAX_CHARS);

  $('#clearBtn').onclick = () => { material.value = ''; store.set('material', ''); updateCount(); $('#fileInfo').textContent = ''; };
  $('#sampleBtn').onclick = () => {
    material.value = SAMPLE; store.set('material', SAMPLE); updateCount();
    $('#fileInfo').textContent = 'Loaded sample lesson: Photosynthesis (Biology).';
  };

  $('#file').onchange = async (e) => {
    const f = e.target.files[0]; if (!f) return;
    const info = $('#fileInfo');
    info.innerHTML = '<span class="spin"></span> Reading ' + esc(f.name) + '…';
    try {
      let text;
      if (f.name.toLowerCase().endsWith('.pdf') || f.type === 'application/pdf') text = await readPdf(f);
      else text = await f.text();
      material.value = text.trim(); store.set('material', material.value); updateCount();
      info.textContent = `Loaded ${f.name} (${text.length.toLocaleString()} characters).`;
    } catch (err) {
      info.textContent = 'Could not read that file: ' + err.message;
    }
    e.target.value = '';
  };

  async function readPdf(file) {
    if (!window.pdfjsLib) {
      await new Promise((ok, fail) => {
        const s = document.createElement('script');
        s.src = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js';
        s.onload = ok; s.onerror = () => fail(new Error('PDF reader needs an internet connection'));
        document.head.appendChild(s);
      });
      window.pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
    }
    const pdf = await window.pdfjsLib.getDocument({ data: await file.arrayBuffer() }).promise;
    const pages = [];
    for (let i = 1; i <= pdf.numPages; i++) {
      const c = await (await pdf.getPage(i)).getTextContent();
      pages.push(c.items.map((it) => it.str).join(' '));
      if (pages.join('\n').length > MAX_CHARS * 2) break;
    }
    const text = pages.join('\n\n');
    if (!text.trim()) throw new Error('no text found (it may be a scanned PDF)');
    return text;
  }

  // ---------- tabs ----------
  $$('.tab').forEach((t) => t.onclick = () => {
    $$('.tab').forEach((x) => x.setAttribute('aria-selected', String(x === t)));
    $$('.panel').forEach((p) => p.classList.toggle('active', p.dataset.panel === t.dataset.tab));
    if (t.dataset.tab === 'log') renderLog();
  });

  // ---------- helpers ----------
  function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }

  // Tiny, safe markdown renderer: escapes everything first, then adds formatting.
  function md(src) {
    const blocks = [];
    let s = esc(src).replace(/```[^\n]*\n([\s\S]*?)(```|$)/g, (_, code) => { blocks.push(code); return `\u0000${blocks.length - 1}\u0000`; });
    const inline = (t) => t
      .replace(/`([^`]+)`/g, '<code>$1</code>')
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    const out = []; let list = null;
    const closeList = () => { if (list) { out.push(`</${list}>`); list = null; } };
    for (const line of s.split('\n')) {
      let m;
      if (/^\u0000\d+\u0000$/.test(line.trim())) { closeList(); out.push(line.trim()); }
      else if ((m = line.match(/^\s*#{1,6}\s+(.*)$/))) { closeList(); out.push(`<h3>${inline(m[1])}</h3>`); }
      else if ((m = line.match(/^\s*[-*•]\s+(.*)$/))) { if (list !== 'ul') { closeList(); out.push('<ul>'); list = 'ul'; } out.push(`<li>${inline(m[1])}</li>`); }
      else if ((m = line.match(/^\s*\d+[.)]\s+(.*)$/))) { if (list !== 'ol') { closeList(); out.push('<ol>'); list = 'ol'; } out.push(`<li>${inline(m[1])}</li>`); }
      else if (!line.trim()) { closeList(); }
      else { closeList(); out.push(`<p>${inline(line)}</p>`); }
    }
    closeList();
    return out.join('').replace(/\u0000(\d+)\u0000/g, (_, i) => `<pre><code>${blocks[i]}</code></pre>`);
  }

  const mode = () => $('#mode').value;
  $('#mode').value = store.get('mode', 'auto');
  $('#mode').onchange = () => store.set('mode', mode());

  // ---------- test log ----------
  let log = store.get('log', []);
  function addLog(entry) { log.unshift(entry); log = log.slice(0, 300); store.set('log', log); renderLog(); }
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
      : '<tr><td colspan="6" class="hint">No requests yet. Try the tutor, a summary or a quiz.</td></tr>';
  }
  $('#resetLog').onclick = () => { log = []; store.set('log', log); renderLog(); };
  $('#exportBtn').onclick = () => {
    const rows = [['time', 'task', 'mode', 'answered_by', 'seconds', 'ok', 'error']].concat(
      log.map((l) => [new Date(l.t).toISOString(), l.task, l.mode, l.via || '', l.secs.toFixed(2), l.ok, l.err || '']));
    const csv = rows.map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
    a.download = 'course-ai-test-log.csv'; a.click();
  };
  renderLog();

  // ---------- AI calls ----------
  async function errorText(res) {
    try {
      const j = await res.json();
      const m = j?.error?.message || '';
      if (res.status === 503 || /no models|no available|exhausted|All \d+ routed/i.test(m)) {
        return 'No free AI provider could answer right now. ' + (m ? `(${m.slice(0, 220)})` : '') + ' Tip: add a free Gemini or Groq key in ⚙️ Settings.';
      }
      if (res.status === 429) return 'Rate limited. Wait a minute and try again. ' + m;
      return m || `Error ${res.status}`;
    } catch { return `Error ${res.status}`; }
  }

  /** Streams a chat completion; calls onText(fullTextSoFar). Returns {text, via, secs}. */
  async function streamChat(messages, task, onText) {
    const t0 = performance.now(); const m = mode();
    try {
      const res = await fetch('/api/chat', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ model: m, messages, stream: true }) });
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
      if (!text.trim()) throw new Error('The AI returned an empty answer. Try again or switch AI mode.');
      const secs = (performance.now() - t0) / 1000;
      addLog({ t: Date.now(), task, mode: m, via, secs, ok: true });
      return { text, via, secs };
    } catch (err) {
      addLog({ t: Date.now(), task, mode: m, via: '', secs: (performance.now() - t0) / 1000, ok: false, err: err.message });
      throw err;
    }
  }

  async function completeChat(messages, task) {
    let last = '';
    return streamChat(messages, task, (t) => { last = t; });
  }

  function parseJson(text) {
    let t = text.replace(/```(?:json)?/gi, '').trim();
    const a = t.indexOf('{'), b = t.lastIndexOf('}');
    if (a >= 0 && b > a) t = t.slice(a, b + 1);
    return JSON.parse(t);
  }

  const metaLine = (r) => `answered by ${r.via || 'unknown model'} · ${r.secs.toFixed(1)}s`;
  const needMaterial = () => { if (!getMaterial()) { alert('Please paste some course material first (or click "Try a sample lesson").'); return true; } return false; };
  const busy = (btn, on, label) => { btn.disabled = on; if (on) { btn.dataset.l = btn.textContent; btn.innerHTML = '<span class="spin"></span> ' + (label || 'Working…'); } else btn.textContent = btn.dataset.l || btn.textContent; };

  // ---------- chat ----------
  let history = [];
  const chatlog = $('#chatlog');
  function addBubble(cls, html) {
    $('#chatEmpty')?.remove();
    const d = document.createElement('div'); d.className = 'msg ' + cls; d.innerHTML = html;
    chatlog.appendChild(d); chatlog.scrollTop = chatlog.scrollHeight; return d;
  }
  async function ask(q) {
    q = q.trim(); if (!q) return;
    const btn = $('#askBtn'); busy(btn, true, '');
    addBubble('user', esc(q));
    const mat = getMaterial();
    const system = 'You are a friendly, patient tutor helping a student with their course. Explain clearly, use short paragraphs and simple examples. ' +
      (mat ? 'Base your answers on the COURSE MATERIAL below. If the answer is not in the material, say so and then answer from general knowledge.\n\nCOURSE MATERIAL:\n"""\n' + mat + '\n"""' : 'The student has not provided course material; answer from general knowledge.');
    history.push({ role: 'user', content: q });
    const bubble = addBubble('ai', '<span class="spin"></span>');
    try {
      const r = await streamChat([{ role: 'system', content: system }, ...history.slice(-10)], 'Tutor chat', (t) => { bubble.innerHTML = `<div class="md">${md(t)}</div>`; chatlog.scrollTop = chatlog.scrollHeight; });
      history.push({ role: 'assistant', content: r.text });
      bubble.insertAdjacentHTML('beforeend', `<div class="meta">${esc(metaLine(r))}</div>`);
    } catch (err) {
      history.pop(); bubble.className = 'msg err'; bubble.textContent = err.message;
    } finally { busy(btn, false); }
  }
  $('#askBtn').onclick = () => { const q = $('#question').value; $('#question').value = ''; ask(q); };
  $('#question').addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); $('#askBtn').click(); } });
  $$('[data-quick]').forEach((b) => b.onclick = () => ask(b.dataset.quick));
  $('#newChat').onclick = () => { history = []; chatlog.innerHTML = '<div class="empty" id="chatEmpty">New chat started.</div>'; };

  // ---------- summary ----------
  const SUM = {
    bullet: 'Summarise the material as 6-10 clear bullet points covering the key ideas. Start with a one-line overview.',
    short: 'Summarise the material in one clear paragraph of about 120 words.',
    exam: 'Create an exam revision sheet: key terms with short definitions, the main concepts, any formulas or processes step by step, and 3 likely exam questions.',
    eli5: 'Explain the material as if to a curious 12-year-old, using everyday comparisons. Keep it under 200 words.',
  };
  $('#sumBtn').onclick = async () => {
    if (needMaterial()) return;
    const btn = $('#sumBtn'); busy(btn, true); $('#sumMeta').textContent = '';
    const out = $('#sumOut'); out.innerHTML = '<span class="spin"></span>';
    try {
      const r = await streamChat([
        { role: 'system', content: 'You are an expert teacher who writes clear study notes. Use markdown.' },
        { role: 'user', content: SUM[$('#sumStyle').value] + '\n\nMATERIAL:\n"""\n' + getMaterial() + '\n"""' },
      ], 'Summary', (t) => { out.innerHTML = md(t); });
      $('#sumMeta').textContent = metaLine(r);
    } catch (err) { out.innerHTML = `<span class="bad-t">${esc(err.message)}</span>`; }
    finally { busy(btn, false); }
  };

  // ---------- quiz ----------
  async function jsonTask(task, prompt, check) {
    const messages = [
      { role: 'system', content: 'You are a teacher creating study material. Reply with ONLY valid JSON, no markdown fences, no commentary.' },
      { role: 'user', content: prompt + '\n\nMATERIAL:\n"""\n' + getMaterial() + '\n"""' },
    ];
    let lastErr;
    for (let attempt = 0; attempt < 2; attempt++) {
      const r = await completeChat(messages, task + (attempt ? ' (retry)' : ''));
      try { const data = parseJson(r.text); if (check(data)) return { data, r }; lastErr = new Error('The AI answer was missing parts'); }
      catch { lastErr = new Error('The AI did not return valid JSON'); }
    }
    throw new Error(lastErr.message + '. Try again or pick "Smartest available" mode.');
  }

  $('#quizBtn').onclick = async () => {
    if (needMaterial()) return;
    const n = Math.min(10, Math.max(3, +$('#quizN').value || 5));
    const btn = $('#quizBtn'); busy(btn, true); $('#quizMeta').textContent = '';
    const out = $('#quizOut'); out.innerHTML = '<p class="hint"><span class="spin"></span> Writing questions…</p>';
    try {
      const { data, r } = await jsonTask('Quiz',
        `Write ${n} ${$('#quizLevel').value} multiple-choice questions that test understanding of the material. ` +
        'Return JSON exactly like {"questions":[{"question":"...","options":["A","B","C","D"],"answer":0,"explanation":"..."}]} where "answer" is the 0-based index of the correct option.',
        (d) => Array.isArray(d.questions) && d.questions.length && d.questions.every((q) => q.question && Array.isArray(q.options) && q.options.length >= 2));
      renderQuiz(data.questions);
      $('#quizMeta').textContent = metaLine(r);
    } catch (err) { out.innerHTML = `<p class="bad-t">${esc(err.message)}</p>`; }
    finally { busy(btn, false); }
  };

  function renderQuiz(qs) {
    const out = $('#quizOut'); out.innerHTML = '';
    let answered = 0, right = 0;
    const score = document.createElement('div'); score.className = 'score';
    qs.forEach((q, qi) => {
      const correct = Math.max(0, Math.min(q.options.length - 1, Number(q.answer) || 0));
      const box = document.createElement('div'); box.className = 'quiz-q';
      box.innerHTML = `<div class="q">${qi + 1}. ${esc(q.question)}</div>`;
      q.options.forEach((o, oi) => {
        const b = document.createElement('button'); b.className = 'opt'; b.textContent = `${'ABCDEFG'[oi] || oi + 1}. ${o}`;
        b.onclick = () => {
          $$('.opt', box).forEach((x, xi) => { x.disabled = true; if (xi === correct) x.classList.add('right'); });
          if (oi !== correct) b.classList.add('wrong'); else right++;
          answered++;
          if (q.explanation) box.insertAdjacentHTML('beforeend', `<div class="explain">💡 ${esc(q.explanation)}</div>`);
          score.textContent = answered === qs.length ? `🎯 Final score: ${right} / ${qs.length}` : `Score so far: ${right} / ${answered}`;
        };
        box.appendChild(b);
      });
      out.appendChild(box);
    });
    out.appendChild(score);
  }

  // ---------- flashcards ----------
  $('#cardBtn').onclick = async () => {
    if (needMaterial()) return;
    const n = Math.min(16, Math.max(4, +$('#cardN').value || 8));
    const btn = $('#cardBtn'); busy(btn, true); $('#cardMeta').textContent = '';
    const out = $('#cardOut'); out.innerHTML = '<p class="hint"><span class="spin"></span> Making cards…</p>';
    try {
      const { data, r } = await jsonTask('Flashcards',
        `Create ${n} study flashcards for the key terms and ideas. Return JSON exactly like {"cards":[{"front":"term or question","back":"short answer"}]}.`,
        (d) => Array.isArray(d.cards) && d.cards.length && d.cards.every((c) => c.front && c.back));
      out.innerHTML = '';
      data.cards.forEach((c) => {
        const el = document.createElement('div'); el.className = 'flash'; el.tabIndex = 0;
        const show = (back) => { el.classList.toggle('flipped', back); el.innerHTML = `<div class="side">${back ? 'Answer' : 'Question'}</div><div>${esc(back ? c.back : c.front)}</div>`; };
        let back = false; show(false);
        el.onclick = () => show(back = !back);
        el.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); show(back = !back); } };
        out.appendChild(el);
      });
      $('#cardMeta').textContent = metaLine(r);
    } catch (err) { out.innerHTML = `<p class="bad-t">${esc(err.message)}</p>`; }
    finally { busy(btn, false); }
  };

  // ---------- status + settings ----------
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
      if (!s.freellmapi) { pill.className = 'pill bad'; txt.textContent = 'FreeLLMAPI not running'; warn.classList.remove('hidden'); warn.textContent = 'The FreeLLMAPI router is not running. Run ~/CourseAI/start.sh (or double-click "Course AI" on your Desktop).'; return; }
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
  refreshStatus(); setInterval(refreshStatus, 20000);

  const SAMPLE = `Photosynthesis — Biology, Unit 3

Photosynthesis is the process by which green plants, algae and some bacteria convert light energy into chemical energy stored in glucose. It takes place mainly in the chloroplasts of leaf cells, which contain the green pigment chlorophyll.

Overall equation:
6CO2 + 6H2O + light energy → C6H12O6 + 6O2

Stage 1 — Light-dependent reactions (thylakoid membranes):
- Chlorophyll absorbs light, mostly red and blue wavelengths.
- Water molecules are split (photolysis), releasing oxygen as a by-product.
- The energy is used to make ATP and NADPH.

Stage 2 — Light-independent reactions / Calvin cycle (stroma):
- The enzyme RuBisCO fixes carbon dioxide onto RuBP.
- ATP and NADPH from stage 1 are used to turn the fixed carbon into glucose (G3P).

Limiting factors: light intensity, carbon dioxide concentration and temperature. Increasing one factor raises the rate only until another factor becomes limiting. Very high temperatures denature enzymes and reduce the rate.

Importance: photosynthesis produces the oxygen most living things need, forms the base of almost every food chain, and removes carbon dioxide from the atmosphere.`;
})();
</script>
</body>
</html>
COURSEAI_EMBED_EOF
info "App installed ✓"

# ---------------------------------------------------------------------------
step "4/5  Settings, scripts and shortcut"
# ---------------------------------------------------------------------------
SECRETS="$COURSEAI_HOME/config/secrets.env"
if [ ! -f "$SECRETS" ]; then
  umask 077
  ENC="$("$NODE_BIN" -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')"
  PASS="$("$NODE_BIN" -e 'console.log(require("crypto").randomBytes(9).toString("base64url"))')"
  cat > "$SECRETS" <<EOF
# Generated by the Course AI installer. Keep this file private.
ENCRYPTION_KEY=$ENC
COURSEAI_ADMIN_EMAIL=student@courseai.local
COURSEAI_ADMIN_PASSWORD=$PASS
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
[ "$APP_PORT" = "$WANT_APP" ] || info "Port $WANT_APP is busy, Study Buddy will use $APP_PORT"

cat > "$COURSEAI_HOME/config/runtime.env" <<EOF
NODE_BIN=$NODE_BIN
APP_PORT=$APP_PORT
FL_PORT=$FL_PORT
EOF

cat > "$COURSEAI_HOME/start.sh" <<'EOF'
#!/usr/bin/env bash
# Starts FreeLLMAPI and the Study Buddy app in the background, then opens the browser.
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
  ADMIN_JSON="$("$NODE_BIN" -e 'console.log(JSON.stringify({admin:{email:process.env.COURSEAI_ADMIN_EMAIL,password:process.env.COURSEAI_ADMIN_PASSWORD}}))')"
  # cd first, then background node itself, so the saved PID is node's (stop.sh kills it).
  cd "$H/freellmapi"
  NODE_ENV=production HOST=127.0.0.1 PORT="$FL_PORT" \
    FREEAPI_DB_PATH="$H/data/freeapi.db" FREEAPI_CONFIG_JSON="$ADMIN_JSON" \
    nohup "$NODE_BIN" server/dist/index.js >>"$H/logs/freellmapi.log" 2>&1 &
  echo $! >"$H/run/freellmapi.pid"
  cd "$H"
  wait_for "http://127.0.0.1:$FL_PORT/api/ping" 60 || { echo "✗ FreeLLMAPI did not start. See $H/logs/freellmapi.log" >&2; tail -n 20 "$H/logs/freellmapi.log" >&2; exit 1; }
fi

if running app; then echo "• Study Buddy already running"; else
  echo "• Starting Study Buddy on http://127.0.0.1:$APP_PORT …"
  COURSEAI_PORT="$APP_PORT" FREELLMAPI_URL="http://127.0.0.1:$FL_PORT" FREELLMAPI_DIR="$H/freellmapi" \
    FREEAPI_DB_PATH="$H/data/freeapi.db" COURSEAI_ADMIN_EMAIL="$COURSEAI_ADMIN_EMAIL" COURSEAI_ADMIN_PASSWORD="$COURSEAI_ADMIN_PASSWORD" \
    nohup "$NODE_BIN" "$H/app/server.mjs" >>"$H/logs/app.log" 2>&1 & echo $! >"$H/run/app.pid"
  wait_for "http://127.0.0.1:$APP_PORT/api/health" 20 || { echo "✗ Study Buddy did not start. See $H/logs/app.log" >&2; tail -n 20 "$H/logs/app.log" >&2; exit 1; }
fi

echo ""
echo "✅ Course AI is running:"
echo "   Study Buddy:          http://127.0.0.1:$APP_PORT"
echo "   FreeLLMAPI dashboard: http://127.0.0.1:$FL_PORT   (login: $COURSEAI_ADMIN_EMAIL / $COURSEAI_ADMIN_PASSWORD)"
echo "   Stop it with:         $H/stop.sh"
if [ "${COURSEAI_NO_OPEN:-0}" != "1" ]; then
  if command -v open >/dev/null; then open "http://127.0.0.1:$APP_PORT"
  elif command -v xdg-open >/dev/null; then xdg-open "http://127.0.0.1:$APP_PORT" >/dev/null 2>&1 || true; fi
fi
EOF

cat > "$COURSEAI_HOME/stop.sh" <<'EOF'
#!/usr/bin/env bash
# Stops the Study Buddy app and FreeLLMAPI.
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

cat > "$COURSEAI_HOME/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
# Removes Course AI completely (app, FreeLLMAPI, your data and keys).
H="$(cd "$(dirname "$0")" && pwd)"
read -r -p "Delete $H and everything in it? [y/N] " a
[ "$a" = "y" ] || [ "$a" = "Y" ] || { echo "Cancelled."; exit 0; }
"$H/stop.sh" || true
rm -f "$HOME/Desktop/Course AI.command"
rm -rf "$H"
echo "Course AI removed."
EOF
chmod +x "$COURSEAI_HOME/start.sh" "$COURSEAI_HOME/stop.sh" "$COURSEAI_HOME/uninstall.sh"

if [ "$OS" = "Darwin" ] && [ -d "$HOME/Desktop" ]; then
  cat > "$HOME/Desktop/Course AI.command" <<EOF
#!/usr/bin/env bash
# Double-click to start Course AI Study Buddy.
"$COURSEAI_HOME/start.sh"
echo ""
echo "You can close this window; Course AI keeps running. To stop it: $COURSEAI_HOME/stop.sh"
EOF
  chmod +x "$HOME/Desktop/Course AI.command"
  info "Desktop shortcut: Course AI.command (double-click to start)"
fi
info "Scripts: $COURSEAI_HOME/start.sh · stop.sh · uninstall.sh"

# ---------------------------------------------------------------------------
step "5/5  Starting"
# ---------------------------------------------------------------------------
if [ "${COURSEAI_NO_START:-0}" = "1" ]; then
  info "Skipped (COURSEAI_NO_START=1). Start later with: $COURSEAI_HOME/start.sh"
  exit 0
fi
COURSEAI_NO_OPEN=1 "$COURSEAI_HOME/start.sh"

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

if [ "${COURSEAI_NO_OPEN:-0}" != "1" ]; then
  if command -v open >/dev/null; then open "http://127.0.0.1:$APP_PORT"
  elif command -v xdg-open >/dev/null; then xdg-open "http://127.0.0.1:$APP_PORT" >/dev/null 2>&1 || true; fi
fi
bold ""
bold "🎉 Done! Study Buddy is open at http://127.0.0.1:$APP_PORT"
info "Next time, double-click \"Course AI\" on your Desktop (or run $COURSEAI_HOME/start.sh)."
