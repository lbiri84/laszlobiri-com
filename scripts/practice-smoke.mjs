#!/usr/bin/env node
// A gyakorló oldal füstpróbája (gyerekprofilok, eredmények, gyerek mód), valódi Supabase nélkül.
//
// Egy memóriában dolgozó ál-Supabase (auth + PostgREST) a valódi RLS-szabályok szerint
// válaszol: a szülő a háztartás minden gyerekét látja, a párosított tablet csak a hozzá
// rendelteket. A gyakorlas oldalt helyben szolgáljuk ki, a laszlobiri.com kéréseit
// (lib/v1, belépőoldal) a helyi laszlobiri-com fájlokra irányítjuk, tesztkonfigurációval.
//
// Futtatás: node scripts/practice-smoke.mjs [a gyakorlas checkout útvonala]
//           (alapértelmezés: ../gyakorlas; Playwright + Chromium kell)

import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const LB = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const APP = path.resolve(process.argv[2] || path.join(LB, '..', 'gyakorlas'));
const MOCK = 'http://localhost:8765', SITE = 'http://localhost:8769';
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png' };

// ---------------------------------------------------------------- ál-Supabase
const HH = 'aaaaaaaa-0000-0000-0000-000000000000';
const PARENT = 'a1a1a1a1-0000-0000-0000-000000000000';
const db = { pupils: [], results: [], badges: [], devices: [], device_pupils: [], pairings: [], reports: [] };
const users = { [PARENT]: { id: PARENT, is_anonymous: false, email: 'szulo@example.invalid' } };
const refresh = {};
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const now = () => Math.floor(Date.now() / 1000);
function session(uid) {
  const rt = 'rt-' + randomUUID(); refresh[rt] = uid;
  const u = users[uid];
  return { access_token: `${b64({ alg: 'HS256' })}.${b64({ sub: uid, role: 'authenticated', exp: now() + 3600, is_anonymous: u.is_anonymous })}.sig`,
    token_type: 'bearer', expires_in: 3600, expires_at: now() + 3600, refresh_token: rt,
    user: { id: uid, aud: 'authenticated', role: 'authenticated', email: u.email || '', is_anonymous: u.is_anonymous, user_metadata: {} } };
}
const subOf = req => { try { return JSON.parse(Buffer.from((req.headers.authorization || '').split(' ')[1].split('.')[1], 'base64url')).sub; } catch { return null; } };
const isParent = sub => sub === PARENT;
const deviceOf = sub => db.devices.find(d => d.user_id === sub);
const canPupil = (sub, pid) => (isParent(sub) && db.pupils.some(p => p.id === pid)) || (deviceOf(sub) && db.device_pupils.some(x => x.device_user_id === sub && x.pupil_id === pid));
const inList = (q, col) => { const v = q.get(col); if (!v) return null; return v.startsWith('in.(') ? v.slice(4, -1).split(',') : v.startsWith('eq.') ? [v.slice(3)] : null; };
const pick = (row, sel) => (sel && sel !== '*' ? Object.fromEntries(sel.split(',').map(c => c.trim()).map(c => [c, row[c]])) : row);
const err = (status, code, message) => ({ status, body: { code, message } });

function rest(method, table, q, body, sub) {
  const sel = q.get('select');
  if (table === 'profiles') return { status: 200, body: isParent(sub) ? [{ id: PARENT, display_name: 'Szülő', app_role: 'admin' }] : [] };
  if (table === 'households') return { status: 200, body: isParent(sub) ? [{ id: HH }] : [] };
  if (table === 'pupils') {
    if (method === 'GET') return { status: 200, body: db.pupils.filter(p => canPupil(sub, p.id)).map(p => pick(p, sel)) };
    if (method === 'POST') {
      if (!isParent(sub)) return err(403, '42501', 'rls');
      if (db.pupils.some(p => p.nickname.trim().toLowerCase() === body.nickname.trim().toLowerCase())) return err(409, '23505', 'pupils_household_nickname');
      db.pupils.push({ theme: 'slate', ...body, created_at: new Date().toISOString() }); return { status: 201, body: null };
    }
    if (method === 'PATCH') {
      const id = inList(q, 'id')[0], p = db.pupils.find(x => x.id === id);
      // A szülő bármit, a hozzá rendelt tablet csak a színt írhatja (pupils_guard).
      if (p && canPupil(sub, id)) { if (!['slate', 'rose', 'sky'].includes(body.theme)) return err(400, '23514', 'theme'); p.theme = body.theme; }
      return { status: 204 };
    }
    if (method === 'DELETE') {
      if (!isParent(sub)) return { status: 204 };
      const id = inList(q, 'id')[0];
      db.pupils = db.pupils.filter(p => p.id !== id); db.results = db.results.filter(r => r.pupil_id !== id);
      db.badges = db.badges.filter(r => r.pupil_id !== id); db.device_pupils = db.device_pupils.filter(r => r.pupil_id !== id);
      return { status: 204 };
    }
  }
  if (table === 'results' || table === 'pupil_badges') {
    const rows = table === 'results' ? db.results : db.badges;
    if (method === 'GET') { const ids = inList(q, 'pupil_id') || []; return { status: 200, body: rows.filter(r => ids.includes(r.pupil_id) && canPupil(sub, r.pupil_id)).map(r => pick(r, sel)) }; }
    if (method === 'POST') {
      if (!canPupil(sub, body.pupil_id)) return err(403, '42501', 'rls');
      if (table === 'results' && rows.some(r => r.id === body.id)) return err(409, '23505', 'results_pkey');
      if (table === 'pupil_badges' && rows.some(r => r.pupil_id === body.pupil_id && r.badge_id === body.badge_id)) return err(409, '23505', 'pupil_badges_pkey');
      rows.push({ ...body, recorded_by: sub }); return { status: 201, body: null };
    }
  }
  if (table === 'devices') {
    const vis = db.devices.filter(d => isParent(sub) || d.user_id === sub);
    if (method === 'GET') return { status: 200, body: vis.map(d => pick(d, sel)) };
    const id = inList(q, 'user_id')?.[0];
    if (method === 'PATCH') { const d = vis.find(x => x.user_id === id); if (d && body.last_seen_at) d.last_seen_at = body.last_seen_at; return { status: 204 }; }
    if (method === 'DELETE') { if (isParent(sub)) { db.devices = db.devices.filter(d => d.user_id !== id); db.device_pupils = db.device_pupils.filter(d => d.device_user_id !== id); } return { status: 204 }; }
  }
  if (table === 'question_reports') {
    if (method === 'POST') {
      if (!body.pupil_id || !canPupil(sub, body.pupil_id)) return err(403, '42501', 'rls');
      if (db.reports.some(r => r.id === body.id)) return err(409, '23505', 'question_reports_pkey');
      db.reports.push({ ...body, status: 'new', recorded_by: sub, created_at: new Date().toISOString() }); return { status: 201, body: null };
    }
    if (!isParent(sub)) return { status: 200, body: method === 'GET' ? [] : null };
    if (method === 'GET') return { status: 200, body: db.reports.filter(r => !q.get('status') || r.status === q.get('status').slice(3)).map(r => pick(r, sel)) };
    if (method === 'PATCH') { const r = db.reports.find(x => x.id === inList(q, 'id')[0]); if (r) r.status = body.status; return { status: 204 }; }
  }
  if (table === 'device_pupils') return { status: 200, body: db.device_pupils.filter(x => isParent(sub) || x.device_user_id === sub).map(x => pick(x, sel)) };
  if (table === 'rpc/create_pairing') {
    if (!isParent(sub) || !body.p_pupils.every(id => db.pupils.some(p => p.id === id))) return err(403, '42501', 'nincs jogosultság');
    const A = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; let c = ''; for (let i = 0; i < 8; i++) c += A[Math.floor(Math.random() * 32)];
    db.pairings.push({ code: c, pupils: body.p_pupils, label: body.p_label, used: false });
    return { status: 200, body: c.slice(0, 4) + '-' + c.slice(4) };
  }
  if (table === 'rpc/claim_pairing') {
    if (!users[sub]?.is_anonymous) return err(403, '42501', 'csak névtelen fiók');
    const norm = String(body.p_code).toUpperCase().replace(/[^A-Z0-9]/g, '');
    const p = db.pairings.find(x => x.code === norm && !x.used);
    if (!p) return { status: 200, body: 'invalid' };
    p.used = true;
    db.devices.push({ user_id: sub, household_id: HH, label: p.label, created_at: new Date().toISOString(), last_seen_at: new Date().toISOString() });
    p.pupils.forEach(pid => db.device_pupils.push({ device_user_id: sub, pupil_id: pid }));
    return { status: 200, body: 'ok' };
  }
  return { status: 404, body: { code: 'PGRST205', message: 'unknown ' + table } };
}

let anonEnabled = true;
const mock = http.createServer(async (req, res) => {
  const u = new URL(req.url, MOCK);
  const h = { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'access-control-expose-headers': '*' };
  const send = (status, body) => { res.writeHead(status, h); res.end(body == null ? '' : JSON.stringify(body)); };
  if (req.method === 'OPTIONS') return send(204);
  let raw = ''; for await (const c of req) raw += c;
  const body = raw ? JSON.parse(raw) : null;
  const sub = subOf(req);
  if (u.pathname === '/auth/v1/signup') {
    if (!anonEnabled) return send(422, { code: 'anonymous_provider_disabled', msg: 'Anonymous sign-ins are disabled' });
    const id = randomUUID(); users[id] = { id, is_anonymous: true }; return send(200, session(id));
  }
  if (u.pathname === '/auth/v1/token') { const uid = refresh[body?.refresh_token]; return uid && users[uid] ? send(200, session(uid)) : send(400, { error: 'invalid_grant' }); }
  if (u.pathname === '/auth/v1/user') return users[sub] ? send(200, session(sub).user) : send(401, { code: 'user_not_found' });
  if (u.pathname === '/auth/v1/logout') return send(204);
  if (u.pathname.startsWith('/rest/v1/')) {
    const r = rest(req.method, u.pathname.slice(9), u.searchParams, body, sub);
    const one = /vnd\.pgrst\.object/.test(req.headers.accept || '');
    if (one && Array.isArray(r.body)) return r.body.length === 1 ? send(200, r.body[0]) : send(406, { code: 'PGRST116', message: 'rows' });
    return send(r.status, r.body);
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
await new Promise(r => site.listen(8769, r));

// ---------------------------------------------------------------- böngésző
let failed = 0;
const check = (ok, m) => { console.log((ok ? '  rendben  ' : '  HIBA     ') + m); if (!ok) failed++; };
const browser = await chromium.launch();
async function device({ parent }) {
  const ctx = await browser.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 800 }, permissions: ['clipboard-read', 'clipboard-write'] });
  await ctx.route('https://fonts.googleapis.com/**', r => r.abort());
  await ctx.route('https://laszlobiri.com/**', async r => {
    const u = new URL(r.request().url());
    if (u.pathname === '/lib/v1/config.js') return r.fulfill({ contentType: 'text/javascript', headers: { 'access-control-allow-origin': '*' }, body: `export const SUPABASE_URL='${MOCK}';export const SUPABASE_ANON_KEY='anon';export const isConfigured=true;` });
    let f = path.join(LB, u.pathname); if (f.endsWith('/')) f += 'index.html';
    try { r.fulfill({ body: await readFile(f), contentType: TYPES[path.extname(f)], headers: { 'access-control-allow-origin': '*' } }); } catch { r.fulfill({ status: 404 }); }
  });
  if (parent) await ctx.addCookies([{ name: 'sb-localhost-auth-token', value: 'base64-' + b64(session(PARENT)), domain: 'localhost', path: '/' }]);
  const page = await ctx.newPage();
  page.errors = [];
  page.on('pageerror', e => page.errors.push(e.message));
  page.on('dialog', d => d.accept());
  return { ctx, page };
}
const visible = page => page.waitForFunction(() => !document.getElementById('lb-gate') && document.querySelector('#app').children.length > 0, null, { timeout: 15000 });
const wait = ms => new Promise(r => setTimeout(r, ms));
// SHOTS=<mappa>: képernyőképek a fő nézetekről (kézi szemrevételezéshez).
const shot = async (page, name) => { if (process.env.SHOTS) await page.screenshot({ path: path.join(process.env.SHOTS, name + '.png'), fullPage: true }); };
async function playRound(page, topic = 'abc') {
  await page.click(`[data-go="${topic}"]`);
  for (let i = 0; i < 10; i++) { await page.click('[data-pick="0"]'); await page.click('[data-next]'); }
  await page.waitForSelector('.result');
}
// Megvárjuk, amíg a kimenő sor kiürül (minden eredmény felment), és a szerver visszaigazolta.
const settle = async page => {
  await page.waitForFunction(() => { try { return JSON.parse(localStorage.getItem('gyakorlo.outbox.v1') || '[]').length === 0; } catch { return false; } }, null, { timeout: 15000 });
  await page.waitForTimeout(200);
};

try {
  // ---- szülő
  const P = await device({ parent: true });
  await P.page.addInitScript(() => { if (!sessionStorage.getItem('s')) { localStorage.setItem('gyakorlo.v1', '{"points":999}'); sessionStorage.setItem('s', '1'); } });
  await P.page.goto(SITE);
  await visible(P.page);
  check(await P.page.evaluate(() => localStorage.getItem('gyakorlo.v1')) === null, 'a régi helyi pontok (gyakorlo.v1) törlődtek');
  await P.page.waitForSelector('text=Még nincs gyerekprofil');
  check(true, 'szülő: üres állapot, „Gyerekprofil létrehozása”');

  await P.page.click('[data-go="parent"]');
  await P.page.waitForSelector('#nick');
  for (const [nick, av] of [['Mókus', 'fox'], ['Süni', 'owl'], ['<u>X</u>', 'cat']]) {
    await P.page.fill('#nick', nick); await P.page.check(`input[name=av][value=${av}]`, { force: true });
    await P.page.click('[data-go="addpupil"]'); await P.page.waitForFunction(n => document.querySelector('.msg').textContent.includes(n + ' profilja elkészült'), nick);
  }
  check(db.pupils.length === 3, 'szülő: három gyerekprofil a szerveren');
  await P.page.fill('#nick', 'mókus'); await P.page.click('[data-go="addpupil"]');
  await P.page.waitForFunction(() => document.querySelector('.msg').textContent === 'Ilyen becenév már van.');
  check(true, 'szülő: azonos becenév nem hozható létre');
  check((await P.page.$$('.card u')).length === 0 && (await P.page.textContent('.card')).includes('<u>X</u>'), 'a becenév szövegként jelenik meg, nem HTML-ként (esc)');
  await P.page.click(`[data-delpupil="${db.pupils[2].id}"]`);
  await P.page.waitForFunction(() => document.querySelector('.msg').textContent.includes('törölve'));
  check(db.pupils.length === 2, 'szülő: gyerekprofil törölhető');

  await P.page.click('[data-go="who"]');
  await P.page.waitForSelector('[data-pupil]');
  check((await P.page.$$('[data-pupil]')).length === 2, '„Ki gyakorol?”: két gyerek');
  await shot(P.page, 'ki-gyakorol');
  const mokus = db.pupils.find(p => p.nickname === 'Mókus').id;
  const bgOf = page => page.evaluate(() => [document.documentElement.dataset.theme, getComputedStyle(document.body).backgroundColor]);

  // Színtéma: a szülői nézetben már nincs választó; Mókus a saját kezdőképernyőjén választ.
  await P.page.click('[data-go="parent"]');
  await P.page.waitForSelector('#nick');
  check((await P.page.$$('[data-theme-pupil], input[name=th]')).length === 0, 'téma: a szülői nézetben nincs színválasztó');
  await P.page.click('[data-go="who"]');
  await P.page.waitForSelector('[data-pupil]');
  await P.page.click(`[data-pupil="${mokus}"]`);
  await P.page.waitForSelector('.whobar');
  check((await bgOf(P.page))[0] === 'slate', 'téma: alapból palakék');
  await P.page.click(`[data-theme-pupil="${mokus}"][data-theme-val="rose"]`);
  await settle(P.page);
  check(db.pupils.find(p => p.id === mokus).theme === 'rose', 'téma: Mókus a kezdőképernyőn rózsaszínt választ (szerveren)');
  await P.page.click('[data-go="who"]');
  await P.page.waitForSelector('[data-pupil]');
  check((await bgOf(P.page))[0] === 'slate', 'téma: a „Ki gyakorol?” marad palakék');
  await P.page.click(`[data-pupil="${mokus}"]`);
  await P.page.waitForSelector('.whobar');
  check((await P.page.textContent('.whobar')).includes('Mókus'), 'kezdőképernyő: Mókus gyakorol');
  const [th, bg] = await bgOf(P.page);
  check(th === 'rose' && bg === 'rgb(38, 29, 27)', `téma: Mókus kezdőképernyője rózsaszín (${th}, ${bg})`);
  check(await P.page.evaluate(() => document.querySelector('meta[name=theme-color]').content) === '#261d1b', 'téma: a böngésző sávszíne is igazodik');
  await shot(P.page, 'rozsaszin-kezdo');

  await playRound(P.page);
  await settle(P.page);
  const r1 = db.results.filter(r => r.pupil_id === mokus);
  check(r1.length === 1 && r1[0].kind === 'round' && r1[0].answered === 10 && r1[0].points === r1[0].score * 10 + (r1[0].score === 10 ? 50 : 0), `a befejezett kör a szerveren (${r1[0]?.score}/10, ${r1[0]?.points} pont)`);
  check(db.badges.some(b => b.pupil_id === mokus && b.badge_id === 'elso'), 'az „Első kör” jelvény a szerveren');

  // Félbehagyott kör nem számít.
  await P.page.click('[data-go="home"]');
  await P.page.click('[data-go="abc"]'); await P.page.click('[data-pick="0"]'); await P.page.click('[data-go="home"]');
  await wait(500);
  check(db.results.filter(r => r.pupil_id === mokus).length === 1, 'a félbehagyott kör nem mentődik');
  const ptsShown = await P.page.textContent('.pts');
  check(ptsShown === `${r1[0].points} pont`, `a kezdőképernyő a szerver szerinti pontot mutatja (${ptsShown})`);

  // Jelvények: a jó válaszok és a környezetismeret-fejezetek jelvényei is látszanak.
  await P.page.click('[data-go="badges"]');
  await P.page.waitForSelector('text=Jelvényeim');
  const bcount = await P.page.textContent('.qcount');
  check(/\/24$/.test(bcount.trim()), `jelvények: 24 van (${bcount.trim()})`);
  check(await P.page.isVisible('text=Kétezer jó válasz') && await P.page.isVisible('text=Rovarszakértő'), 'jelvények: „Kétezer jó válasz” és „Rovarszakértő” a listában');
  const bgroups = await P.page.$$eval('h2.group', hs => hs.map(h => h.textContent.trim()));
  check(bgroups.length === 6 && bgroups[0].startsWith('Kezdés és kitartás') && bgroups.some(g => g.startsWith('Környezetismeret 0/8')), `jelvények: csoportosítva (${bgroups.join(' | ')})`);
  check(await P.page.$$eval('.badge', b => b.length) === 24, 'jelvények: minden jelvény pontosan egyszer szerepel');
  await shot(P.page, 'jelvenyek-csoportok');
  await P.page.click('[data-go="home"]');

  // ---- párosító kód csak Mókusra
  await P.page.click('[data-go="parent"]');
  await P.page.waitForSelector('#dlabel');
  const suni = db.pupils.find(p => p.nickname === 'Süni').id;
  await P.page.uncheck(`input[name=pp][value="${suni}"]`);
  await P.page.click('[data-go="newcode"]');
  await P.page.waitForSelector('.codebox');
  const code = (await P.page.textContent('.codebox')).trim();
  check(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(code), `párosító kód: ${code}`);
  await shot(P.page, 'szuloi-nezet');
  check((await P.page.textContent('.card .rowi')).includes('utoljára'), 'szülői nézet: Mókus statisztikája');

  // ---- gyerek tablet
  const T = await device({ parent: false });
  await T.page.goto(SITE);
  await T.page.waitForURL(u => u.hostname === 'laszlobiri.com', { timeout: 10000 });
  check(T.page.url().startsWith('https://laszlobiri.com/belepes/'), 'tablet belépés és párosítás nélkül: belépőoldal');

  await T.page.goto(SITE + '/#parositas');
  await visible(T.page);
  await T.page.fill('#pcode', 'AAAA-AAAA'); await T.page.fill('#ppin', '1234'); await T.page.fill('#ppin2', '1234');
  await T.page.click('[data-go="dopair"]');
  await T.page.waitForFunction(() => /Hibás vagy lejárt/.test(document.querySelector('.msg').textContent));
  check(true, 'tablet: hibás kódot elutasít');
  await T.page.fill('#pcode', code.toLowerCase()); await T.page.fill('#ppin', '1234'); await T.page.fill('#ppin2', '1243');
  await T.page.click('[data-go="dopair"]');
  await T.page.waitForFunction(() => document.querySelector('.msg').textContent === 'A két PIN nem egyezik.');
  check(true, 'tablet: eltérő PIN-t nem fogad el');
  await shot(T.page, 'parositas');
  await T.page.fill('#pcode', code.toLowerCase()); await T.page.fill('#ppin', '1234'); await T.page.fill('#ppin2', '1234');
  await T.page.click('[data-go="dopair"]');
  await T.page.waitForSelector('.whobar', { timeout: 15000 });
  check(db.devices.length === 1, 'tablet: párosítva (egy eszköz a szerveren)');
  check((await T.page.textContent('.whobar')).includes('Mókus') && !(await T.page.$('[data-go="who"]')), 'tablet: csak Mókus, másik gyerekre nem vált');
  check(!(await T.page.$('[data-go="parent"]')), 'tablet: nincs szülői nézet');
  check((await T.page.evaluate(() => document.cookie)).indexOf('auth-token') < 0, 'tablet: az eszközfiók nem a közös sütiben van');
  check(T.page.url().indexOf('#parositas') < 0, 'tablet: a párosítás után a kezdőképernyőre ugrik');
  check((await bgOf(T.page))[0] === 'rose', 'téma: Mókus tabletje rózsaszín');
  // A tableten a gyerek visszaállítja, offline is (a kimenő soron át megy fel).
  await T.ctx.setOffline(true);
  await T.page.click(`[data-theme-pupil="${mokus}"][data-theme-val="slate"]`);
  check((await bgOf(T.page))[0] === 'slate', 'téma: a tableten offline is azonnal vált');
  await T.ctx.setOffline(false);
  await T.page.evaluate(() => window.dispatchEvent(new Event('online')));
  await settle(T.page);
  check(db.pupils.find(p => p.id === mokus).theme === 'slate', 'téma: a tablet választása visszatérő hálózatnál a szerverre került');
  // Égkék (világos) téma a tableten.
  await T.page.click(`[data-theme-pupil="${mokus}"][data-theme-val="sky"]`);
  await settle(T.page);
  const sky = await T.page.evaluate(() => [document.documentElement.dataset.theme, getComputedStyle(document.body).backgroundColor, getComputedStyle(document.querySelector('.mk .l')).fill]);
  check(sky[0] === 'sky' && sky[1] === 'rgb(231, 248, 252)' && sky[2] === 'rgb(0, 0, 0)', `téma: égkék, világos háttér, a jel L betűje fekete (${sky.join(', ')})`);
  check(db.pupils.find(p => p.id === mokus).theme === 'sky', 'téma: az égkék a szerverre került');
  await shot(T.page, 'egkek-kezdo');
  await T.page.click(`[data-theme-pupil="${mokus}"][data-theme-val="rose"]`);
  await settle(T.page);
  await T.page.reload(); await visible(T.page);
  check(await T.page.evaluate(() => document.documentElement.dataset.theme) === 'rose', 'téma: újratöltéskor rögtön rózsaszín (nincs villanás)');
  await shot(T.page, 'tablet-kezdo');

  // Tablet offline kör.
  await T.ctx.setOffline(true);
  await playRound(T.page);
  await T.page.click('[data-go="home"]');
  await T.page.waitForFunction(() => /Offline · 1 eredmény vár/.test(document.querySelector('.foot').textContent));
  check(true, 'tablet offline: „Offline · 1 eredmény vár”');
  await T.ctx.setOffline(false);
  await T.page.evaluate(() => window.dispatchEvent(new Event('online')));
  await settle(T.page);
  const dev = db.devices[0].user_id;
  check(db.results.filter(r => r.pupil_id === mokus).length === 2 && db.results.some(r => r.recorded_by === dev), 'tablet: az offline kör visszatérő hálózatnál felment');

  // Hibás feladat jelentése a tableten (a kör közben).
  await T.page.waitForSelector('.whobar');
  await T.page.click('[data-go="mondat"]');
  await T.page.click('[data-go="report"]');
  await T.page.waitForSelector('[data-report="bad_question"]');
  await shot(T.page, 'jelentes');
  await T.page.click('[data-report="bad_question"]');
  await T.page.waitForSelector('text=Köszönjük! A szülő megnézi');
  check(await T.page.isDisabled('[data-go="report"]'), 'jelentés: elküldve, ugyanaz a kérdés nem jelenthető újra');
  await settle(T.page);
  const rep = db.reports[0];
  check(db.reports.length === 1 && rep.reason === 'bad_question' && rep.topic === 'mondat' && rep.recorded_by === dev && rep.choices.length >= 2 && rep.prompt.length > 0,
    `jelentés: a szerveren a kérdés pillanatképével (${rep?.topic}: „${rep?.prompt}”, ${rep?.choices?.length} válasz)`);
  check(!/[<>]/.test(rep.prompt + rep.body + rep.choices.join('') + rep.explain), 'jelentés: HTML nélkül, csak szöveg');
  await T.page.click('[data-pick="0"]');
  check(await T.page.isDisabled('[data-go="report"]'), 'jelentés: válasz után is jelentve marad');
  await T.page.click('[data-go="home"]');

  // A szülő látja, másolja (a gyerek neve nélkül), és lezárja.
  await P.page.click('[data-go="who"]'); await P.page.click('[data-go="parent"]');
  await P.page.waitForSelector('[data-rep]');
  check((await P.page.textContent('.rep')).includes('Hibás a kérdés'), 'jelentés: a szülői nézetben megjelenik');
  await P.page.click('[data-go="copyreports"]');
  await P.page.waitForFunction(() => /vágólapon/.test(document.querySelector('.msg').textContent));
  const clip = await P.page.evaluate(() => navigator.clipboard.readText());
  check(clip.includes('Hibás a kérdés') && clip.includes('téma: mondat') && clip.includes('Kérdés:') && !clip.includes('Mókus'), 'jelentés: a másolt szöveg a javításhoz kell, a gyerek neve nincs benne');
  await P.page.click(`[data-rep="${rep.id}"][data-repstatus="fixed"]`);
  await P.page.waitForFunction(() => /Javítottként lezárva/.test(document.querySelector('.msg').textContent));
  check(rep.status === 'fixed' && !(await P.page.$('[data-rep]')), 'jelentés: „Javítva” után lezárul és eltűnik a listából');

  // Jutalom 500 pontonként: a gyerek választ (akasztófa / szókereső / falbontó).
  const sum = db.results.filter(r => r.pupil_id === mokus).reduce((t, r) => t + r.points, 0);
  for (let need = 490 - sum; need > 0; need -= 198) db.results.push({ id: randomUUID(), pupil_id: mokus, kind: 'round', topic: 'abc', score: 0, best_streak: 0, answered: 10, correct: 0, points: Math.min(198, need), created_at: new Date(Date.now() - 86400000).toISOString(), recorded_by: dev });
  await T.page.evaluate(() => window.dispatchEvent(new Event('online')));
  await settle(T.page); await T.page.waitForTimeout(500);
  check((await T.page.textContent('.pts')) === '490 pont', `jutalom: 490 pontnál még nincs (${await T.page.textContent('.pts')})`);
  let offered = false;
  for (let i = 0; i < 6 && !offered; i++) { await playRound(T.page); offered = !!(await T.page.$('.mgoffer')); if (!offered) await T.page.click('[data-go="home"]'); }
  check(offered, 'jutalom: 500 pont átlépésekor felajánlja a minijátékot');
  check((await T.page.$$('.mgoffer [data-go="mg-hm"], .mgoffer [data-go="mg-ws"], .mgoffer [data-go="mg-bo"]')).length === 3, 'jutalom: választható az akasztófa, a szókereső és a falbontó');
  await shot(T.page, 'jutalom');

  // Falbontó: győzelem.
  await T.page.click('[data-go="mg-bo"]');
  await T.page.waitForSelector('#boCanvas');
  await T.page.waitForTimeout(300);
  await shot(T.page, 'falbonto');
  const bo = await T.page.evaluate(() => ({ n: window.__gyakorlo.BO.bricks.length, lives: window.__gyakorlo.BO.lives, row: window.__gyakorlo.BO.colors.rows[0] }));
  check(bo.n === 12 && bo.lives === 3, `falbontó: 12 tégla, 3 élet (${bo.n}, ${bo.lives})`);
  check(bo.row === '#d77ca2', `falbontó: a téglák a gyerek témájának színét használják (rózsaszín: ${bo.row})`);
  await T.page.click('#boCanvas');
  await T.page.waitForFunction(() => !window.__gyakorlo.BO.ready);
  check(true, 'falbontó: koppintásra indul a labda');
  await T.page.evaluate(() => window.__gyakorlo.BO.bricks.forEach(b => { b.alive = false; }));
  await T.page.waitForSelector('text=Lebontottad a falat');
  await settle(T.page);
  check(db.results.some(r => r.pupil_id === mokus && r.kind === 'breakout' && r.points === 10), 'falbontó: a győzelem +10 pont a szerveren');
  check(db.badges.some(b => b.pupil_id === mokus && b.badge_id === 'falbonto'), 'falbontó: „Falbontó” jelvény');
  check((await T.page.$$('[data-go="mg-bo"], [data-go="mg-hm"], [data-go="mg-ws"]')).length === 0, 'egy jutalom, egy játék: nincs „még egy” gomb');

  // Akasztófa: két segítség, kérésre.
  await T.page.click('[data-go="home"]');
  await T.page.evaluate(() => { const b = document.createElement('button'); b.dataset.go = 'mg-hm'; b.id = 'tmphm'; document.getElementById('app').appendChild(b); });
  await T.page.click('#tmphm');
  await T.page.waitForSelector('.hm');
  const hm0 = await T.page.evaluate(() => ({ miss: window.__gyakorlo.MG.miss.length, got: window.__gyakorlo.MG.got.length, w: window.__gyakorlo.MG.word }));
  await T.page.click('[data-go="hmhint"]');
  const hm1 = await T.page.evaluate(() => ({ miss: window.__gyakorlo.MG.miss.length, got: window.__gyakorlo.MG.got.slice(), w: window.__gyakorlo.MG.word }));
  check(hm1.got.length === hm0.got + 1 && hm1.got[0] === hm1.w[0] && hm1.miss === 0, `akasztófa: az 1. segítség megmutatja az első betűt (${hm1.w}: ${hm1.got[0]}), életet nem visz`);
  check(await T.page.isVisible('text=1. segítség: megmutattam egy betűt'), 'akasztófa: az 1. segítség szövege látszik');
  const done1 = await T.page.evaluate(() => window.__gyakorlo.MG.done);
  if (!done1) {
    await T.page.click('[data-go="hmhint"]');
    check(await T.page.isVisible('text=2. segítség'), 'akasztófa: kérhető a 2. segítség');
    check(!(await T.page.$('[data-go="hmhint"]')), 'akasztófa: két segítség után nincs több');
  }
  await shot(T.page, 'akasztofa-segitseg');

  // Falbontó: három kiesett labda után vége, pont nélkül.
  await T.page.click('[data-go="home"]');
  await T.page.evaluate(() => { const b = document.createElement('button'); b.dataset.go = 'mg-bo'; b.id = 'tmpbo'; document.getElementById('app').appendChild(b); });
  await T.page.click('#tmpbo');
  await T.page.waitForSelector('#boCanvas');
  for (let i = 0; i < 3; i++) {
    await T.page.evaluate(() => { const B = window.__gyakorlo.BO; B.ready = false; B.vx = 0; B.vy = 320; B.by = 392; });
    await T.page.waitForTimeout(400);
  }
  await T.page.waitForSelector('text=Most nem sikerült. Legközelebb');
  check(db.results.filter(r => r.kind === 'breakout').length === 1, 'falbontó: 3 kiesett labda után vége, a vesztes játék nem ad pontot');
  await T.page.click('[data-go="home"]');

  // Kilépés a gyerek módból.
  await T.page.click('[data-go="kidexit"]');
  await T.page.fill('#kpin', '0000'); await T.page.click('[data-go="dokidexit"]');
  await T.page.waitForFunction(() => document.querySelector('.msg[role=status]').textContent === 'Hibás PIN.');
  check(true, 'tablet: hibás PIN-nel nem lép ki');
  await T.page.fill('#kpin', '1234'); await T.page.click('[data-go="dokidexit"]');
  await T.page.waitForURL(u => u.hostname === 'laszlobiri.com', { timeout: 15000 });
  check(await T.page.evaluate(() => 1), 'tablet: helyes PIN után kilép, és a belépőoldalra kerül');

  // Szülő: az eszköz látszik, visszavonható.
  await P.page.click('[data-go="who"]'); await P.page.click('[data-go="parent"]');
  await P.page.waitForSelector('[data-revoke]');
  await P.page.click('[data-revoke]');
  await P.page.waitForFunction(() => document.querySelector('.msg').textContent === 'A tablet visszavonva.');
  check(db.devices.length === 0, 'szülő: a tablet visszavonható');

  // „Ez az eszköz legyen a gyerek tablet” (a szülő saját eszközén).
  const Q = await device({ parent: true });
  await Q.page.goto(SITE); await visible(Q.page);
  await Q.page.click('[data-go="parent"]'); await Q.page.waitForSelector('#dlabel');
  await Q.page.click('[data-go="thisdevice"]');
  await Q.page.waitForSelector('#pcode');
  check(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(await Q.page.inputValue('#pcode')), 'ez az eszköz: a kód előre kitöltve');
  await Q.page.fill('#ppin', '4321'); await Q.page.fill('#ppin2', '4321'); await Q.page.click('[data-go="dopair"]');
  await Q.page.waitForSelector('[data-pupil], .whobar', { timeout: 15000 });
  check((await Q.ctx.cookies()).filter(c => /auth-token/.test(c.name)).length === 0, 'ez az eszköz: a szülő munkamenete törlődött');
  check(await Q.page.evaluate(() => localStorage.getItem('lb-device')) === '1' && Q.page.url().startsWith(SITE), 'ez az eszköz: gyerek módban maradt (nem dobta a belépőoldalra)');
  check((await Q.page.$$('[data-pupil]')).length === 2, 'ez az eszköz: mindkét gyerek választható (mindkettő volt bejelölve)');

  // Névtelen belépés kikapcsolva a szerveren.
  anonEnabled = false;
  const N = await device({ parent: false });
  await N.page.goto(SITE + '/#parositas'); await visible(N.page);
  await N.page.fill('#pcode', 'ABCD-EFGH'); await N.page.fill('#ppin', '1234'); await N.page.fill('#ppin2', '1234');
  await N.page.click('[data-go="dopair"]');
  await N.page.waitForFunction(() => /nincs bekapcsolva/.test(document.querySelector('.msg').textContent));
  check(true, 'kikapcsolt névtelen belépésnél érthető hibaüzenet');

  const errs = [P, T, Q, N].flatMap(x => x.page.errors);
  check(errs.length === 0, 'nincs JavaScript-hiba' + (errs.length ? ': ' + errs.join(' | ') : ''));
} catch (e) {
  failed++; console.log('  HIBA     ' + e.stack);
} finally {
  await browser.close(); mock.close(); site.close();
}

console.log(failed ? `\n${failed} ellenőrzés elbukott.` : '\nMinden ellenőrzés rendben.');
process.exit(failed ? 1 : 0);
