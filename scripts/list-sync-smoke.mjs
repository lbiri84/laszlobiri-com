#!/usr/bin/env node
// A közös bevásárlólista szinkronjának füstpróbája, két "telefonnal", valódi Supabase nélkül.
//
// Egy memóriában dolgozó ál-PostgREST szerver (lists, items, item_history, bump_history)
// ugyanúgy érvényesíti a név szerinti egyediséget (23505), mint az adatbázis. A
// bevasarlo-lista oldalt helyben szolgáljuk ki, a laszlobiri.com kéréseit (lib/v1) a
// helyi laszlobiri-com fájlokra irányítjuk, tesztkonfigurációval.
//
// Futtatás: node scripts/list-sync-smoke.mjs [a bevasarlo-lista checkout útvonala]
//           (alapértelmezés: ../bevasarlo-lista; Playwright + Chromium kell)

import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const LB = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const APP = path.resolve(process.argv[2] || path.join(LB, '..', 'bevasarlo-lista'));
const MOCK = 'http://localhost:8765', SITE = 'http://localhost:8767';
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png' };

// ---------------------------------------------------------------- ál-adatbázis
const HH = 'aaaaaaaa-0000-0000-0000-000000000000', LIST = 'aaaaaaaa-1111-0000-0000-000000000000';
const items = new Map();       // id → sor
const history = new Map();     // name_key → sor
const nowIso = () => new Date().toISOString();
const dup = name => ({ status: 409, body: { code: '23505', message: `duplicate key value violates unique constraint "${name}"` } });

function insertItem(r) {
  if (items.has(r.id)) return dup('items_pkey');
  for (const it of items.values()) if (it.list_id === r.list_id && it.name_key && it.name_key === r.name_key) return dup('items_live_name_key_unique');
  items.set(r.id, { qty: '', cat: 'egyeb', done: false, added_at: nowIso(), deleted_at: null, ...r, updated_at: nowIso() });
  return { status: 201, body: null };
}
function patchItem(id, f) {
  const it = items.get(id); if (!it) return { status: 204 };
  const next = { ...it, ...f, updated_at: nowIso() };
  if (next.deleted_at) next.name_key = null;
  if (next.name_key) for (const o of items.values()) if (o.id !== id && o.list_id === next.list_id && o.name_key === next.name_key) return dup('items_live_name_key_unique');
  if (!next.deleted_at && !next.name_key) return { status: 400, body: { code: '23514', message: 'items_live_has_key' } };
  items.set(id, next); return { status: 204 };
}
// PostgREST-szűrők közül csak amit az app használ: col=eq.X, col=is.null
function match(row, q) {
  for (const [k, v] of q) {
    if (['select', 'order', 'limit'].includes(k)) continue;
    if (v.startsWith('eq.') && String(row[k]) !== decodeURIComponent(v.slice(3))) return false;
    if (v === 'is.null' && row[k] !== null) return false;
  }
  return true;
}
const pick = (row, sel) => (sel && sel !== '*' ? Object.fromEntries(sel.split(',').map(c => c.trim()).map(c => [c, row[c]])) : row);

const mock = http.createServer(async (req, res) => {
  const u = new URL(req.url, MOCK);
  const h = { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'access-control-expose-headers': '*' };
  const send = (status, body) => { res.writeHead(status, h); res.end(body == null ? '' : JSON.stringify(body)); };
  if (req.method === 'OPTIONS') return send(204);
  let raw = ''; for await (const c of req) raw += c;
  const body = raw ? JSON.parse(raw) : null;
  const q = [...u.searchParams.entries()];
  const one = /vnd\.pgrst\.object/.test(req.headers.accept || '');
  const out = rows => {
    if (!one) return send(200, rows);
    return rows.length === 1 ? send(200, rows[0]) : send(406, { code: 'PGRST116', message: 'no rows' });
  };
  const sel = u.searchParams.get('select');

  if (u.pathname === '/auth/v1/user') return send(200, globalThis.USERS[req.headers.authorization?.split('.')[1]] || globalThis.USERS.a1);
  if (u.pathname === '/rest/v1/profiles') { const row = { id: 'x', display_name: 'Teszt', app_role: 'user' }; return out([row]); }
  if (u.pathname === '/rest/v1/lists') return out([{ id: LIST, household_id: HH }].map(r => pick(r, sel)));
  if (u.pathname === '/rest/v1/items') {
    if (req.method === 'POST') { const r = insertItem(body); return send(r.status, r.body); }
    if (req.method === 'PATCH') { const id = decodeURIComponent(u.searchParams.get('id').slice(3)); const r = patchItem(id, body); return send(r.status, r.body); }
    let rows = [...items.values()].filter(r => match(r, q));
    rows.sort((a, b) => a.added_at.localeCompare(b.added_at));
    return out(rows.map(r => pick(r, sel)));
  }
  if (u.pathname === '/rest/v1/item_history') {
    const rows = [...history.values()].sort((a, b) => b.count - a.count).slice(0, 200);
    return out(rows.map(r => pick(r, sel)));
  }
  if (u.pathname === '/rest/v1/rpc/bump_history') {
    const k = body.p_name_key, cur = history.get(k);
    history.set(k, { name_key: k, name: body.p_name, cat: body.p_cat, count: (cur?.count || 0) + 1, last_used: nowIso() });
    return send(204);
  }
  send(404, {});
});
await new Promise(r => mock.listen(8765, r));

const site = http.createServer(async (req, res) => {
  let f = path.join(APP, decodeURIComponent(new URL(req.url, SITE).pathname));
  if (f.endsWith('/')) f += 'index.html';
  try { const d = await readFile(f); res.writeHead(200, { 'content-type': TYPES[path.extname(f)] || 'application/octet-stream' }); res.end(d); }
  catch { res.writeHead(404); res.end(); }
});
await new Promise(r => site.listen(8767, r));

// ---------------------------------------------------------------- böngésző
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const now = () => Math.floor(Date.now() / 1000);
function sessionFor(id, name) {
  const user = { id, aud: 'authenticated', role: 'authenticated', email: name + '@example.invalid', user_metadata: { name } };
  return { access_token: `${b64({ alg: 'HS256' })}.${b64({ sub: id, role: 'authenticated', exp: now() + 3600 })}.sig`, token_type: 'bearer', expires_in: 3600, expires_at: now() + 3600, refresh_token: 'r', user };
}
globalThis.USERS = {};

let failed = 0;
const check = (ok, m) => { console.log((ok ? '  rendben  ' : '  HIBA     ') + m); if (!ok) failed++; };

const browser = await chromium.launch();
async function phone(id, name) {
  const ctx = await browser.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 760 } });
  await ctx.route('https://fonts.googleapis.com/**', r => r.abort());
  await ctx.route('https://laszlobiri.com/**', async r => {
    const u = new URL(r.request().url());
    if (u.pathname === '/lib/v1/config.js') return r.fulfill({ contentType: 'text/javascript', headers: { 'access-control-allow-origin': '*' }, body: `export const SUPABASE_URL='${MOCK}';export const SUPABASE_ANON_KEY='anon';export const isConfigured=true;` });
    try { r.fulfill({ body: await readFile(path.join(LB, u.pathname)), contentType: TYPES[path.extname(u.pathname)], headers: { 'access-control-allow-origin': '*' } }); } catch { r.fulfill({ status: 404 }); }
  });
  await ctx.addCookies([{ name: 'sb-localhost-auth-token', value: 'base64-' + b64(sessionFor(id, name)), domain: 'localhost', path: '/' }]);
  const page = await ctx.newPage();
  page.errors = [];
  page.on('pageerror', e => page.errors.push(e.message));
  // A realtime websocket a mockban nincs; a böngésző ezt hibaként naplózza, de nem számít.
  return { ctx, page };
}
const names = page => page.$$eval('.item .label', els => els.map(e => e.childNodes[0].textContent.trim()));
const add = async (page, text) => { await page.click('#input'); await page.keyboard.type(text); await page.keyboard.press('Enter'); };
// Szinkron kiváltása, és megvárjuk a lista tényleges lekérését (+ a kirajzolást).
const syncNow = async page => {
  const got = page.waitForResponse(r => r.url().startsWith(MOCK + '/rest/v1/items?') && r.request().method() === 'GET', { timeout: 10000 });
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await got;
  await page.waitForTimeout(100);
};
const settle = page => page.waitForFunction(() => !document.getElementById('syncState').textContent, null, { timeout: 10000 });
const wait = ms => new Promise(r => setTimeout(r, ms));

try {
  const A = await phone('a1a1a1a1-0000-0000-0000-000000000000', 'Anya');
  const B = await phone('b1b1b1b1-0000-0000-0000-000000000000', 'Apa');

  // Régi, belépés nélküli lista: az új verzió törli.
  await A.page.addInitScript(() => { if (!sessionStorage.getItem('seeded')) { localStorage.setItem('bevasarlo-lista.v1', '{"items":[{"id":"x","name":"Régi","qty":"","cat":"egyeb","done":false,"added":1}],"history":[]}'); sessionStorage.setItem('seeded', '1'); } });

  await A.page.goto(SITE); await B.page.goto(SITE);
  await A.page.waitForFunction(() => !document.getElementById('lb-gate'));
  await B.page.waitForFunction(() => !document.getElementById('lb-gate'));
  await wait(500);
  check(await A.page.evaluate(() => localStorage.getItem('bevasarlo-lista.v1')) === null, 'a régi helyi lista (v1) törlődött');
  check((await names(A.page)).length === 0, 'a régi tétel nem került fel a közös listára');

  // A felvesz két tételt → a szerverre kerül → B látja.
  await add(A.page, '2 l tej'); await add(A.page, 'kenyér');
  await settle(A.page);
  check([...items.values()].filter(r => !r.deleted_at).length === 2, 'A két tétele a szerverre került');
  await syncNow(B.page); await settle(B.page); await wait(300);
  check(JSON.stringify((await names(B.page)).sort()) === JSON.stringify(['Kenyér', 'Tej']), 'B látja A tételeit');

  // B kipipálja a tejet → A látja.
  await B.page.click('.item:has-text("Tej") .check');
  await settle(B.page);
  check([...items.values()].find(r => r.name === 'Tej')?.done === true, 'B pipálása a szerverre került');
  await syncNow(A.page); await settle(A.page); await wait(300);
  check(await A.page.isChecked('.item:has-text("Tej") .check'), 'A látja B pipálását');

  // Offline: B offline felveszi az almát és a sajtot, A közben online felveszi a sajtot.
  await B.ctx.setOffline(true);
  await B.page.evaluate(() => window.dispatchEvent(new Event('offline')));
  await add(B.page, 'alma'); await add(B.page, '3 db sajt');
  await wait(800);
  const st = await B.page.textContent('#syncState');
  check(/Offline · \d+ változás vár/.test(st), `offline állapotjelzés: "${st}"`);
  check((await names(B.page)).includes('Alma'), 'offline felvett tétel azonnal látszik');
  await B.page.reload().catch(() => {});
  await add(A.page, 'sajt'); await settle(A.page);

  // B újra online: a sor elmegy, a sajt nem lesz dupla.
  await B.ctx.setOffline(false);
  await B.page.goto(SITE); await B.page.waitForFunction(() => !document.getElementById('lb-gate'));
  await settle(B.page); await wait(300);
  const live = [...items.values()].filter(r => !r.deleted_at);
  check(live.filter(r => r.name_key === 'sajt').length === 1, 'két telefon ugyanazt vette fel: egy sajt van a szerveren');
  check(live.find(r => r.name_key === 'sajt')?.qty === '3 db', 'a később beérkező mennyiség (3 db) érvényesül');
  check(live.some(r => r.name_key === 'alma'), 'az offline felvett alma a szerverre került');
  await syncNow(A.page); await settle(A.page); await wait(300);
  const an = (await names(A.page)).sort(), bn = (await names(B.page)).sort();
  check(JSON.stringify(an) === JSON.stringify(bn), `a két lista egyezik: ${an.join(', ')}`);

  // Törlés és visszavonás.
  await A.page.click('.item:has-text("Kenyér") .del');
  await settle(A.page);
  check([...items.values()].find(r => r.name === 'Kenyér')?.deleted_at, 'törlés: soft delete a szerveren');
  await A.page.click('#undoBtn'); await settle(A.page);
  check(![...items.values()].find(r => r.name === 'Kenyér')?.deleted_at, 'visszavonás: a tétel újra él');

  // Kipipáltak törlése.
  await A.page.click('#clearDone'); await settle(A.page);
  check([...items.values()].find(r => r.name === 'Tej')?.deleted_at, 'kipipáltak törlése: a tej törölve');

  // Gyorsjavaslatok közösen.
  check(history.get('tej')?.count === 1 && history.get('sajt')?.count >= 1, 'a gyakran vett előzmény a szerverre került (bump_history)');
  await syncNow(B.page); await settle(B.page); await wait(300);
  check((await B.page.$$eval('.chip', els => els.map(e => e.dataset.name))).includes('Tej'), 'B gyorsjavaslatai között ott a tej');

  // XSS: a másik telefon által beírt név szövegként jelenik meg.
  await add(A.page, '<img src=x onerror="window.__xss=1">'); await settle(A.page);
  await syncNow(B.page); await settle(B.page); await wait(300);
  check(!(await B.page.evaluate(() => window.__xss)) && (await B.page.$$('.item img')).length === 0, 'a másik felhasználó szövege nem fut kódként (esc)');

  // Linkes küldés megszűnt.
  check((await A.page.$('#linkBtn')) === null && (await A.page.$('#importDlg')) === null, 'a linkes küldés és importálás eltűnt');

  const errs = [...A.page.errors, ...B.page.errors];
  check(errs.length === 0, 'nincs JavaScript-hiba' + (errs.length ? ': ' + errs.join(' | ') : ''));
} catch (e) {
  failed++; console.log('  HIBA     ' + e.stack);
} finally {
  await browser.close(); mock.close(); site.close();
}

console.log(failed ? `\n${failed} ellenőrzés elbukott.` : '\nMinden ellenőrzés rendben.');
process.exit(failed ? 1 : 0);
