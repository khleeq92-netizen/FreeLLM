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
