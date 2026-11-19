#!/usr/bin/env node
// A társasházi elszámoló füstpróbája, valódi Supabase nélkül.
//
// Egy memóriában dolgozó ál-PostgREST (th_* táblák és függvények) ugyanazokat az
// ellenőrzéseket végzi, mint az adatbázis: a lakásrészek összege = a tétel összege, a
// lezáráskor az utalások kiadják az egyenlegeket, írni csak a kezelő tud, az utalást a két
// érintett lakás is jelölheti. A tarsashaz oldalt helyben szolgáljuk ki, a laszlobiri.com
// kéréseit (lib/v1) a helyi fájlokra irányítjuk.
//
// Szereplők: kezelő (em-4) és egy lakó (fsz-2). A számpélda (kitalált): egy kéthavi
// időszak víz-, szemét-, villany- és zsáktétellel, vízóra-leolvasással.
//
// Futtatás: node scripts/tarsashaz-smoke.mjs [a tarsashaz checkout útvonala]
//           (alapértelmezés: ../tarsashaz). SHOTS=<mappa>: képernyőképek.

import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const LB = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const APP = path.resolve(process.argv[2] || path.join(LB, '..', 'tarsashaz'));
const MOCK = 'http://localhost:8775', SITE = 'http://localhost:8777';
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json', '.png': 'image/png' };
const FLATS = ['fsz-1', 'fsz-2', 'em-3', 'em-4'];

// ---------------------------------------------------------------- ál-adatbázis
const K = 'k0k0k0k0-0000-0000-0000-000000000000', L = 'l2l2l2l2-0000-0000-0000-000000000000', R = 'r1r1r1r1-0000-0000-0000-000000000000';
const WHO = { [K]: { flat: 'em-4', manager: true }, [L]: { flat: 'fsz-2', manager: false }, [R]: { flat: 'fsz-1', manager: false } };
const T = { th_flats: [], th_residents: [], th_periods: [], th_readings: [], th_items: [], th_item_shares: [], th_transfers: [] };
const uuid = () => crypto.randomUUID();
const err = (status, code, message) => ({ status, body: { code, message } });

function balances(pid) {
  const bal = Object.fromEntries(FLATS.map(f => [f, 0]));
  for (const it of T.th_items.filter(i => i.period_id === pid)) {
    bal[it.paid_by] += it.amount;
    for (const s of T.th_item_shares.filter(s => s.item_id === it.id)) bal[s.flat] -= s.amount;
  }
  return bal;
}

function rpc(fn, p, who) {
  const mgr = who?.manager;
  const needMgr = () => (mgr ? null : err(403, '42501', 'Csak a kezelő módosíthat.'));
  const open = pid => T.th_periods.find(x => x.id === pid && x.status === 'open');
  switch (fn) {
    case 'th_me': return { status: 200, body: who || { flat: null, manager: false } };
    case 'th_save_flats': {
      if (needMgr()) return needMgr();
      const tot = FLATS.reduce((a, f) => a + Number(p.p[f]), 0);
      if (tot !== 10000) return err(400, '22023', 'A négy lakás tulajdoni hányadának összege 10 000 legyen.');
      T.th_flats = FLATS.map((f, i) => ({ code: f, share: Number(p.p[f]), sort: i + 1 }));
      return { status: 200, body: null };
    }
    case 'th_save_residents': {
      if (needMgr()) return needMgr();
      for (const f of FLATS) { T.th_residents = T.th_residents.filter(r => !(r.flat === f && r.valid_from === p.p_valid_from)); T.th_residents.push({ flat: f, valid_from: p.p_valid_from, count: Number(p.p_counts[f]) }); }
      return { status: 200, body: null };
    }
    case 'th_open_period': {
      if (needMgr()) return needMgr();
      if (T.th_periods.some(x => x.status === 'open')) return err(400, '22023', 'Már van nyitott időszak.');
      const id = uuid(); T.th_periods.push({ id, name: p.p_name, starts_on: p.p_starts_on, ends_on: null, status: 'open', closed_at: null, note: null, created_at: new Date().toISOString() });
      return { status: 200, body: id };
    }
    case 'th_rename_period': {
      if (needMgr()) return needMgr();
      Object.assign(T.th_periods.find(x => x.id === p.p_id), { name: p.p_name.trim(), starts_on: p.p_starts_on, ends_on: p.p_ends_on, note: (p.p_note || '').trim() || null });
      return { status: 200, body: null };
    }
    case 'th_save_item': {
      if (needMgr()) return needMgr();
      const it = p.p;
      if (!open(it.period_id)) return err(400, '22023', 'Az időszak le van zárva.');
      const tot = Object.values(it.shares).reduce((a, v) => a + Number(v), 0);
      if (tot !== it.amount) return err(400, '22023', `A lakásrészek összege (${tot}) nem egyezik a tétel összegével (${it.amount}).`);
      // Mint az adatbázis: nem beszálló lakás nem szerepelhet a részek között, 0 Ft-tal sem.
      if (Object.keys(it.shares).some(f => !it.participants.includes(f))) return err(400, '22023', 'Csak beszálló lakásnak lehet része.');
      const { shares, ...row } = it;
      T.th_items = T.th_items.filter(x => x.id !== it.id); T.th_items.push({ ...row, created_at: new Date().toISOString() });
      T.th_item_shares = T.th_item_shares.filter(s => s.item_id !== it.id);
      for (const [f, v] of Object.entries(shares)) if (v) T.th_item_shares.push({ item_id: it.id, flat: f, amount: v });
      return { status: 200, body: it.id };
    }
    case 'th_delete_item': {
      if (needMgr()) return needMgr();
      T.th_items = T.th_items.filter(x => x.id !== p.p_id); T.th_item_shares = T.th_item_shares.filter(s => s.item_id !== p.p_id);
      return { status: 200, body: null };
    }
    case 'th_save_reading': {
      if (needMgr()) return needMgr();
      const r = { id: p.p.id || uuid(), note: null, ...p.p };
      T.th_readings = T.th_readings.filter(x => x.id !== r.id); T.th_readings.push(r);
      return { status: 200, body: r.id };
    }
    case 'th_close_period': {
      if (needMgr()) return needMgr();
      const bal = balances(p.p_id);
      for (const f of FLATS) {
        const net = p.p_transfers.filter(t => t.to === f).reduce((a, t) => a + t.amount, 0) - p.p_transfers.filter(t => t.from === f).reduce((a, t) => a + t.amount, 0);
        if (Math.abs(net - bal[f]) > Math.min(Math.max(p.p_tolerance || 0, 0), 10)) return err(400, '22023', `Az utalások nem adják ki a(z) ${f} egyenlegét.`);
      }
      if (p.p_transfers.some(t => t.from === t.to || !(t.amount > 0))) return err(400, '22023', 'Hibás utalás.');
      for (const t of p.p_transfers) T.th_transfers.push({ id: uuid(), period_id: p.p_id, from_flat: t.from, to_flat: t.to, amount: t.amount, paid_at: p.p_paid ? new Date().toISOString() : null });
      Object.assign(T.th_periods.find(x => x.id === p.p_id), { status: 'closed', closed_at: new Date().toISOString() });
      return { status: 200, body: null };
    }
    case 'th_reopen_period': {
      if (needMgr()) return needMgr();
      if (T.th_periods.some(x => x.status === 'open')) return err(400, '22023', 'Előbb zárd le a nyitott időszakot.');
      const paid = T.th_transfers.filter(t => t.period_id === p.p_id && t.paid_at).length;
      if (paid && !p.p_force) return err(400, '22023', `Ebben az időszakban már ${paid} utalás megérkezett.`);
      T.th_transfers = T.th_transfers.filter(t => t.period_id !== p.p_id);
      Object.assign(T.th_periods.find(x => x.id === p.p_id), { status: 'open', closed_at: null });
      return { status: 200, body: paid };
    }
    case 'th_delete_period': {
      if (needMgr()) return needMgr();
      const paid = T.th_transfers.filter(t => t.period_id === p.p_id && t.paid_at).length;
      if (paid && !p.p_force) return err(400, '22023', `Ebben az időszakban már ${paid} utalás megérkezett.`);
      const ids = new Set(T.th_items.filter(i => i.period_id === p.p_id).map(i => i.id));
      T.th_periods = T.th_periods.filter(x => x.id !== p.p_id); T.th_items = T.th_items.filter(i => !ids.has(i.id));
      T.th_item_shares = T.th_item_shares.filter(x => !ids.has(x.item_id)); T.th_transfers = T.th_transfers.filter(t => t.period_id !== p.p_id);
      return { status: 200, body: null };
    }
    case 'th_delete_residents': {
      if (needMgr()) return needMgr();
      T.th_residents = T.th_residents.filter(r => r.valid_from !== p.p_valid_from);
      return { status: 200, body: null };
    }
    case 'th_mark_transfer': {
      const t = T.th_transfers.find(x => x.id === p.p_id);
      if (!(mgr || [t.from_flat, t.to_flat].includes(who?.flat))) return err(403, '42501', 'Ezt az utalást nem jelölheted.');
      t.paid_at = p.p_paid ? new Date().toISOString() : null;
      return { status: 200, body: null };
    }
  }
  return err(404, 'PGRST202', 'nincs ilyen függvény: ' + fn);
}

const whoOf = req => { try { return WHO[JSON.parse(Buffer.from(req.headers.authorization.split(' ')[1].split('.')[1], 'base64url')).sub]; } catch { return null; } };
const mock = http.createServer(async (req, res) => {
  const u = new URL(req.url, MOCK);
  const h = { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'access-control-expose-headers': '*' };
  const send = (status, body) => { res.writeHead(status, h); res.end(body == null ? '' : JSON.stringify(body)); };
  if (req.method === 'OPTIONS') return send(204);
  let raw = ''; for await (const c of req) raw += c;
  if (u.pathname === '/auth/v1/user') return send(200, { id: K });
  if (u.pathname === '/rest/v1/profiles') return send(200, [{ id: 'x', display_name: 'Teszt', app_role: 'user' }]);
  if (u.pathname.startsWith('/rest/v1/rpc/')) { const r = rpc(u.pathname.slice(13), raw ? JSON.parse(raw) : {}, whoOf(req)); return send(r.status, r.body); }
  const t = u.pathname.slice(9);
  if (T[t]) {
    if (req.method !== 'GET') return send(403, { code: '42501', message: 'permission denied' });
    let rows = [...T[t]];
    const o = u.searchParams.get('order');
    if (o) { const [c, dir] = o.split('.'); rows.sort((a, b) => String(a[c]).localeCompare(String(b[c]), 'hu', { numeric: true }) * (dir === 'desc' ? -1 : 1)); }
    return send(200, rows);
  }
  send(404, {});
});
await new Promise(r => mock.listen(8775, r));

const site = http.createServer(async (req, res) => {
  let f = path.join(APP, decodeURIComponent(new URL(req.url, SITE).pathname));
  if (f.endsWith('/')) f += 'index.html';
  try { const d = await readFile(f); res.writeHead(200, { 'content-type': TYPES[path.extname(f)] || 'application/octet-stream' }); res.end(d); }
  catch { res.writeHead(404); res.end(); }
});
await new Promise(r => site.listen(8777, r));

// ---------------------------------------------------------------- böngésző
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const now = () => Math.floor(Date.now() / 1000);
const sessionFor = id => ({ access_token: `${b64({ alg: 'HS256' })}.${b64({ sub: id, role: 'authenticated', exp: now() + 3600 })}.sig`, token_type: 'bearer', expires_in: 3600,
  expires_at: now() + 3600, refresh_token: 'r', user: { id, aud: 'authenticated', role: 'authenticated', email: 'x@example.invalid', user_metadata: { name: 'Teszt' } } });

let failed = 0;
const check = (ok, m) => { console.log((ok ? '  rendben  ' : '  HIBA     ') + m); if (!ok) failed++; };
const shot = async (page, name) => { if (process.env.SHOTS) await page.screenshot({ path: path.join(process.env.SHOTS, name + '.png'), fullPage: true }); };

const browser = await chromium.launch();
async function phone(id) {
  // MOBILE=1: telefon emulálása (érintés, mobil böngésző).
  const mobile = process.env.MOBILE ? { isMobile: true, hasTouch: true, userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1' } : {};
  const ctx = await browser.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 800 }, deviceScaleFactor: process.env.SHOTS ? 2 : 1, ...mobile });
  await ctx.route('https://fonts.googleapis.com/**', r => r.abort());
  await ctx.route('https://laszlobiri.com/**', async r => {
    const u = new URL(r.request().url());
    if (u.pathname === '/lib/v1/config.js') return r.fulfill({ contentType: 'text/javascript', headers: { 'access-control-allow-origin': '*' }, body: `export const SUPABASE_URL='${MOCK}';export const SUPABASE_ANON_KEY='anon';export const isConfigured=true;` });
    try { r.fulfill({ body: await readFile(path.join(LB, u.pathname)), contentType: TYPES[path.extname(u.pathname)], headers: { 'access-control-allow-origin': '*' } }); } catch { r.fulfill({ status: 404 }); }
  });
  await ctx.addCookies([{ name: 'sb-localhost-auth-token', value: 'base64-' + b64(sessionFor(id)), domain: 'localhost', path: '/' }]);
  const page = await ctx.newPage();
  page.errors = [];
  page.on('pageerror', e => page.errors.push(e.message));
  page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource|fonts/.test(m.text())) page.errors.push(m.text()); });
  return { ctx, page };
}
// Gépelés számjegyenként, ahogy egy ember (a mező minden leütés után újrarajzolódik).
const typeIn = async (page, sel, text) => { await page.fill(sel, ''); await page.click(sel); await page.keyboard.type(text, { delay: 15 }); };
// Ezres tagolás, ahogy a mezők mutatják („48 620”).
const grp = n => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
const msgIs = (page, re) => page.waitForFunction(r => new RegExp(r).test(document.getElementById('msg')?.textContent || ''), re.source, { timeout: 10000 });
const sharesOf = name => { const it = T.th_items.find(i => i.name === name); return FLATS.map(f => T.th_item_shares.find(s => s.item_id === it?.id && s.flat === f)?.amount || 0); };

try {
  const A = await phone(K);
  const p = A.page;
  await p.goto(SITE + '/');
  await p.waitForSelector('#tabs:not([hidden])');
  check(/Nincs nyitott időszak/.test(await p.textContent('#app')), 'kezdetben nincs nyitott időszak');
  check(await p.textContent('#me') === 'em-4 · kezelő', 'fejléc: em-4 · kezelő');
  await p.click('header .help-btn'); await p.waitForSelector('.help');
  check(await p.textContent('h1') === 'Hogyan számol?' && await p.isVisible('#h-utalasok'), 'súgó: a fejléc „?” gombja megnyitja a leírást');

  // Beállítások
  await p.goto(SITE + '/#/beallitasok');
  await p.waitForSelector('#flatsForm');
  for (const [f, v] of [['fsz-1', 1911], ['fsz-2', 1911], ['em-3', 3089], ['em-4', 3000]]) await p.fill(`#flatsForm [name="${f}"]`, String(v));
  await p.click('#flatsForm button');
  await msgIs(p, /10 000/);
  check(true, 'hányad: a 10 000-től eltérő összeget elutasítja');
  await p.fill('#flatsForm [name="em-4"]', '3089'); await p.click('#flatsForm button');
  await msgIs(p, /Tulajdoni hányad mentve/);
  await p.fill('#resForm [name=valid_from]', '2025-07-01');
  for (const [f, v] of [['fsz-1', 1], ['fsz-2', 4], ['em-3', 4], ['em-4', 4]]) await p.fill(`#resForm [name="${f}"]`, String(v));
  await p.click('#resForm button');
  await msgIs(p, /Lakók száma mentve/);
  check(T.th_flats.length === 4 && T.th_residents.length === 4, 'hányad és létszám mentve');

  // Vízóra: két leolvasás
  for (const [d, main, a, b, c, e] of [['2026-08-03', 1246, 212, 604, 577, 630], ['2026-10-12', 1284, 215, 614, 586, 640]]) {
    await p.goto(SITE + '/#/viz/uj'); await p.waitForSelector('#readingForm');
    await p.fill('[name=read_on]', d); await typeIn(p, '[name=main]', String(main));
    for (const [k, v] of [['fsz1', a], ['fsz2', b], ['em3', c], ['em4', e]]) await typeIn(p, `[name=${k}]`, String(v).replace('.', ','));
    check(await p.inputValue('[name=main]') === grp(main), `leolvasás: a főmérő gépelve is egyben marad, tagolva (${grp(main)})`);
    await p.click('#readingForm button[type=submit]');
    await msgIs(p, /Leolvasás mentve/);
  }
  check(T.th_readings.length === 2, 'két leolvasás mentve');
  check(/6\s*m³/.test(await p.textContent('#app')), 'vízóra: a kerti csap 6 m³ (38 − 32)');

  // Új időszak
  await p.goto(SITE + '/#/idoszakok'); await p.waitForSelector('#newPeriod');
  await p.fill('#newPeriod [name=name]', '2026. szetpember–oktber'); await p.fill('#newPeriod [name=starts_on]', '2026-09-01');
  await p.click('#newPeriod button');
  await msgIs(p, /Az időszak elindult/);
  // Elírt név javítása
  await p.click('[data-act=editperiod]'); await p.waitForSelector('#periodForm');
  await p.fill('#periodForm [name=name]', '2026. szeptember–október');
  await p.fill('#periodForm [name=note]', 'két hónap');
  await p.click('#periodForm button[type=submit]'); await msgIs(p, /Mentve: 2026\. szeptember–október/);
  check(T.th_periods[0].name === '2026. szeptember–október' && T.th_periods[0].note === 'két hónap' && await p.textContent('h1') === '2026. szeptember–október',
    'időszak szerkesztése: a név és a megjegyzés javítható');

  // Tételek
  async function addItem(name, cat, amount, payer, method) {
    await p.goto(SITE + '/#/tetel/uj'); await p.waitForSelector('#itemForm');
    await p.fill('#itemForm [name=name]', name);
    await p.click(`#itemForm label:has([name=category][value=${cat}])`);
    await typeIn(p, '#itemForm [name=amount]', String(amount));
    check(await p.inputValue('#itemForm [name=amount]') === grp(amount), `tétel: az összeg gépelve is egyben marad, tagolva (${grp(amount)})`);
    await p.click(`#itemForm label:has([name=paid_by][value="${payer}"])`);
    await p.click(`#itemForm label:has([name=method][value=${method}])`);
    await p.click('#itemForm button[type=submit]');
    await msgIs(p, /Mentve/);
  }
  await addItem('Víz és csatorna', 'viz', 48620, 'fsz-1', 'viz');
  check(JSON.stringify(sharesOf('Víz és csatorna')) === '[4558,15194,13674,15194]', 'víz: a fogyasztás arányában (3 : 10 : 9 : 10 m³), pontosan 48 620 Ft');
  await addItem('Szemétszállítás', 'szemet', 31200, 'fsz-1', 'letszam');
  check(JSON.stringify(sharesOf('Szemétszállítás')) === '[2400,9600,9600,9600]', 'szemét: lakók száma szerint (1 : 4 : 4 : 4)');
  await addItem('Közös villany', 'villany', 8940, 'fsz-1', 'hanyad');
  check(JSON.stringify(sharesOf('Közös villany')) === '[1708,1708,2762,2762]', 'villany: tulajdoni hányad szerint, kerekítve is 8 940 Ft');
  await addItem('Zöldhulladék-zsák', 'egyeb', 2760, 'em-4', 'egyenlo');
  check(JSON.stringify(sharesOf('Zöldhulladék-zsák')) === '[690,690,690,690]', 'zsák: egyenlő részben');

  // Részleges beszállás: csak em-3 és em-4, tulajdoni hányad szerint → fele-fele
  await p.goto(SITE + '/#/tetel/uj'); await p.waitForSelector('#itemForm');
  await p.fill('#itemForm [name=name]', 'Lépcsőház festék'); await typeIn(p, '#itemForm [name=amount]', '10001');
  await p.keyboard.press('Home'); await p.keyboard.press('ArrowRight'); await p.keyboard.type('2'); await p.keyboard.press('Backspace');
  check(await p.inputValue('#itemForm [name=amount]') === '10 001', 'tétel: a szám közepén szerkesztve is jó a tagolás és a kurzor');
  // Súgó: a Felosztás melletti „?” a leírás megfelelő részére visz, a Vissza után a félkész tétel megmarad
  await p.click('a.q[href="#/sugo/felosztas"]'); await p.waitForSelector('.help');
  check(await p.isVisible('#h-felosztas') && /Vízfogyasztás/.test(await p.textContent('.help')) && /1\s911 \/ 1\s911 \/ 3\s089 \/ 3\s089/.test(await p.textContent('.help')),
    'súgó: a felosztás leírása, a jelenlegi tulajdoni hányaddal');
  await shot(p, 'tarsashaz-sugo');
  await p.click('[data-act=back]'); await p.waitForSelector('#itemForm');
  check(await p.inputValue('#itemForm [name=name]') === 'Lépcsőház festék' && await p.inputValue('#itemForm [name=amount]') === '10 001', 'súgó: vissza után a félkész tétel megmaradt');
  await p.click('#itemForm label:has([name=participants][value="fsz-1"])'); await p.click('#itemForm label:has([name=participants][value="fsz-2"])');
  check(/5\s*001\s*Ft/.test(await p.textContent('.split')) && /5\s*000\s*Ft/.test(await p.textContent('.split')), 'részleges beszállás: az előnézet fele-fele, a kerekítés pontos');
  await shot(p, 'tarsashaz-uj-tetel');
  await p.click('#itemForm button[type=submit]'); await msgIs(p, /Mentve/);
  check(JSON.stringify(sharesOf('Lépcsőház festék')) === '[0,0,5001,5000]', 'részleges beszállás mentve');
  // ... és törlés
  await p.goto(SITE + '/#/tetel/' + T.th_items.find(i => i.name === 'Lépcsőház festék').id); await p.waitForSelector('#itemForm');
  p.once('dialog', d => d.accept());
  await p.click('[data-act=delitem]'); await msgIs(p, /Törölve/);
  check(!T.th_items.some(i => i.name === 'Lépcsőház festék'), 'tétel törlése');

  // em-4 fizetett fsz-2 helyett: kézi felosztás, csak fsz-2 száll be
  await p.goto(SITE + '/#/tetel/uj'); await p.waitForSelector('#itemForm');
  await p.fill('#itemForm [name=name]', 'Tartozás rendezése');
  await typeIn(p, '#itemForm [name=amount]', '60307');
  await p.click('#itemForm label:has([name=paid_by][value="em-4"])');
  for (const f of ['fsz-1', 'em-3', 'em-4']) await p.click(`#itemForm label:has([name=participants][value="${f}"])`);
  await p.click('#itemForm label:has([name=method][value=kezi])');
  await typeIn(p, '#itemForm [name="m_fsz-2"]', '60307');
  await p.click('#itemForm button[type=submit]'); await msgIs(p, /Mentve/);
  check(JSON.stringify(sharesOf('Tartozás rendezése')) === '[0,60307,0,0]', 'kézi, egy lakás: em-4 fizetett fsz-2 helyett, mentve');
  await p.goto(SITE + '/#/tetel/' + T.th_items.find(i => i.name === 'Tartozás rendezése').id); await p.waitForSelector('#itemForm');
  p.once('dialog', d => d.accept());
  await p.click('[data-act=delitem]'); await msgIs(p, /Törölve/);

  // Áttekintés: a nyitott időszak javasolt utalásai (a legkevesebb utalás), vízóra rész nélkül
  const periodUrl = p.url();
  await p.goto(SITE + '/#/'); await p.waitForSelector('.tr');
  const plan = await p.$$eval('.tr', els => els.map(e => e.textContent.replace(/\s+/g, ' ').trim()));
  check(plan.length === 3 && plan.every(t => /→\s*fsz-1/.test(t)) && plan.some(t => /fsz-2\s*→\s*fsz-1\s*27\s192/.test(t)), 'áttekintés: javasolt utalások (3, mind fsz-1 felé)');
  check(!/Vízóra/.test(await p.$$eval('#app h2', hs => hs.map(h => h.textContent).join(' '))), 'áttekintés: nincs vízóra rész');
  check(/most még nem kell utalni/.test(await p.textContent('.pending .pending-note')) && (await p.$$('.pending .tr')).length === 3 && /25\s486/.test(await p.textContent('.pending .card')),
    'áttekintés: a nyitott időszak kiemelt panelen, „most még nem kell utalni” felirattal');
  await shot(p, 'tarsashaz-attekintes');
  await p.goto(periodUrl); await p.waitForSelector('[data-act=preclose]');
  // A felosztás táblázatában felosztási módonként vékony fejléc
  const heads = await p.$$eval('.split-t tr.grp', hs => hs.map(h => h.textContent.trim()));
  check(JSON.stringify(heads) === JSON.stringify(['Vízfogyasztás szerint', 'Lakók száma szerint', 'Tulajdoni hányad szerint', 'Egyenlő részben']) && !(await p.$('.grp-h, .split-t tr.sub')),
    'felosztás: a táblázatban módonként vékony fejléc, összegzés nélkül; a tételek listája az eredeti');
  await shot(p, 'tarsashaz-idoszak');
  // Lezárás
  await p.click('[data-act=preclose]');
  await p.waitForSelector('[data-act=close]');
  await p.click('[data-act=close]');
  await msgIs(p, /Lezárva/);
  const tr = T.th_transfers.map(t => `${t.from_flat}>${t.to_flat}:${t.amount}`).sort().join(' ');
  check(tr === 'em-3>fsz-1:26726 em-4>fsz-1:25486 fsz-2>fsz-1:27192', 'lezárás: három utalás fsz-1 felé (' + tr + ')');
  check(/fsz-2 → fsz-1: 27\s*192\s*Ft/.test(await p.textContent('#chat')), 'chat-szöveg az utalásokkal');
  await shot(p, 'tarsashaz-lezarva');

  // Lakó (fsz-2)
  const B = await phone(L);
  const q = B.page;
  await q.goto(SITE + '/');
  await q.waitForSelector('#tabs:not([hidden])');
  check(/27\s*192\s*Ft/.test(await q.textContent('.hero')) && /fsz-1/.test(await q.textContent('.hero')), 'lakó: az áttekintésen a saját utalása (27 192 Ft fsz-1-nek)');
  check(!(await q.$('a[href="#/tetel/uj"]')) && !(await q.$('a[href="#/viz/uj"]')), 'lakó: nincs szerkesztő gomb');
  check(!(await q.$('.pending')) && (await q.$$('.hero')).length === 1, 'lakó: lezárás után a valódi teendő (utalás) látszik, a nyitott-panel nincs');
  check(await q.$eval('#tabs [data-tab=settings]', e => e.hidden), 'lakó: nincs Beállítások fül');
  // Közvetlen címmel sem nyílik meg egyik szerkesztő oldal sem
  for (const [hash, sel] of [['#/beallitasok', '#flatsForm, #resForm'], ['#/tetel/uj', '#itemForm'], ['#/viz/uj', '#readingForm']]) {
    await q.goto(SITE + '/' + hash); await q.waitForSelector('#app h2, #app h1');
    check(!(await q.$(sel)), `lakó: a(z) ${hash} címen nincs szerkesztő űrlap`);
  }
  await q.goto(SITE + '/#/idoszak/' + T.th_periods[0].id); await q.waitForSelector('#app h1');
  check(!(await q.$('[data-act=editperiod], [data-act=reopen], [data-act=delperiod], [data-act=preclose], a[href="#/tetel/uj"]')), 'lakó: az időszak oldalán nincs szerkesztő gomb');
  await q.goto(SITE + '/#/viz'); await q.waitForSelector('#app h1');
  check(!(await q.$('[data-delreading], a[href="#/viz/uj"]')), 'lakó: a vízóra oldalon nincs szerkesztő gomb');
  await q.goto(SITE + '/');
  await shot(q, 'tarsashaz-lako');
  // Időszak oldala: lezárás után az utalások felül; a lakó csak a saját utalását jelölheti
  await q.goto(SITE + '/#/idoszak/' + T.th_periods[0].id); await q.waitForSelector('[data-paid]');
  check(await q.evaluate(() => { const h = [...document.querySelectorAll('#app h2')].map(x => x.textContent.trim()); return h.includes('Utalások') && h.indexOf('Utalások') < h.indexOf('Tételek'); }),
    'időszak: lezárás után az utalások a tételek előtt');
  await shot(q, 'tarsashaz-lako-utalasok');
  const boxes = await q.$$eval('[data-paid]', els => els.map(e => [e.closest('.tr').textContent.replace(/\s+/g, ' ').trim(), e.disabled]));
  check(boxes.filter(b => !b[1]).length === 1 && /fsz-2/.test(boxes.find(b => !b[1])[0]), 'lakó: csak a saját utalását jelölheti');

  // A fogadó (fsz-1) áttekintése: „Még tartoznak neked”, gombbal
  const C = await phone(R);
  await C.page.goto(SITE + '/'); await C.page.waitForSelector('#tabs:not([hidden])');
  check((await C.page.$$('.todo.owed [data-paidbtn]')).length === 3 && /ma zárult/.test(await C.page.textContent('.todo.owed')), 'fogadó (fsz-1): Teendők, három „Megjött” gomb, „ma zárult”');
  await shot(C.page, 'tarsashaz-fogado');

  // Az utaló (fsz-2) az áttekintésen jelöli: „Elutaltam”
  await q.goto(SITE + '/'); await q.waitForSelector('[data-paidbtn]');
  check(/Még nem utaltad el/.test(await q.textContent('.todo.hero')) && /Elutaltam/.test(await q.textContent('.todo.hero button')), 'lakó: Teendők, „Még nem utaltad el” és „Elutaltam” gomb');
  await q.click('.todo.hero [data-paidbtn]'); await msgIs(q, /Megjelölve: fsz-2 → fsz-1/);
  check(T.th_transfers.find(t => t.from_flat === 'fsz-2').paid_at && !(await q.$('.todo')), 'lakó: egy koppintással megjelölve, a teendő eltűnt');

  // A fogadó a „Megjött” gombbal jelöli em-3 utalását
  await C.page.reload(); await C.page.waitForSelector('.todo.owed');
  check((await C.page.$$('.todo.owed')).length === 2, 'fogadó: az fsz-2 utalása már nem vár');
  await C.page.click('.todo.owed:has-text("em-3") [data-paidbtn]'); await msgIs(C.page, /Megjelölve: em-3 → fsz-1/);
  check(T.th_transfers.find(t => t.from_flat === 'em-3').paid_at, 'fogadó: „Megjött” megjelölve');

  // Egy hét után kiemelt
  T.th_periods[0].closed_at = new Date(Date.now() - 8 * 86400000).toISOString();
  await C.page.reload(); await C.page.waitForSelector('.todo.owed');
  check(!!(await C.page.$('.todo.owed.late')) && /lezárva 8 napja/.test(await C.page.textContent('.todo.owed')), 'fogadó: egy hét után kiemelt („lezárva 8 napja”)');
  await shot(C.page, 'tarsashaz-fogado-kesik');
  T.th_periods[0].closed_at = new Date().toISOString();

  await q.goto(SITE + '/#/idoszakok'); await q.reload(); await q.waitForSelector('.card');
  check(/lezárva, 1 utalás vár/.test(await q.textContent('#app')), 'időszakok: „lezárva, 1 utalás vár”');

  // Kimutatás
  await p.goto(SITE + '/#/kimutatas'); await p.waitForSelector('.hbar');
  check(/91\s*520\s*Ft/.test(await p.textContent('#app')), 'kimutatás: az éves összeg 91 520 Ft');
  await shot(p, 'tarsashaz-kimutatas');

  // Újranyitás, időszak törlése, minden adat törlése (kezelő)
  const pid = T.th_periods[0].id;
  await p.goto(SITE + '/#/idoszak/' + pid); await p.waitForSelector('[data-act=reopen]');
  p.on('dialog', d => d.accept());
  await p.click('[data-act=reopen]'); await msgIs(p, /Újranyitva/);
  check(T.th_periods[0].status === 'open' && T.th_transfers.length === 0, 'újranyitás: megerősítés után nyitott, az utalások törlődtek');

  // Lezárás egyedi utalásokkal: 1 Ft kerekítési eltérés belefér, a túl nagy nem; azonnal kiegyenlítve
  await p.click('[data-act=preclose]'); await p.click('[data-act=custom]');
  await p.waitForSelector('[data-tr-k=amount]');
  const amt0 = '[data-tr-i="0"][data-tr-k="amount"]';
  await typeIn(p, amt0, '27300');
  check(await p.$eval('[data-act=close]', b => b.disabled) && /Túl nagy eltérés/.test(await p.textContent('#app')), 'egyedi utalás: túl nagy eltérésnél a Lezárás tiltva');
  await typeIn(p, amt0, '27193');
  check(!(await p.$eval('[data-act=close]', b => b.disabled)) && /Kerekítési eltérés/.test(await p.textContent('#app')), 'egyedi utalás: 1 Ft eltérés belefér');
  await p.click('[data-act=closepaid]');
  await p.click('[data-act=close]'); await msgIs(p, /kiegyenlítve/);
  check(T.th_periods[0].status === 'closed' && T.th_transfers.length === 3 && T.th_transfers.every(t => t.paid_at) && T.th_transfers.some(t => t.amount === 27193),
    'egyedi utalás: lezárva a megadott utalásokkal, mind kiegyenlítve');
  check(/Kerekítési eltérés az utalásokban/.test(await p.textContent('#app')), 'egyedi utalás: a lezárt időszakon látszik az eltérés');
  await shot(p, 'tarsashaz-egyedi-lezaras');
  await p.click('[data-act=reopen]'); await msgIs(p, /Újranyitva/);
  await p.click('[data-act=delperiod]'); await msgIs(p, /Időszak törölve/);
  check(T.th_periods.length === 0 && T.th_items.length === 0 && T.th_item_shares.length === 0, 'időszak törlése: a tételekkel és a részekkel együtt');
  // Létszám: egy véletlen mai bejegyzés, majd törlése az előzmények közül
  await p.goto(SITE + '/#/beallitasok'); await p.waitForSelector('#resForm');
  await p.fill('#resForm [name=valid_from]', '2026-11-18'); await p.click('#resForm button');
  await msgIs(p, /Lakók száma mentve/);
  check((await p.$$('.hist .row')).length === 2, 'beállítások: a létszám előzményei a létszám alatt (2 bejegyzés)');
  await p.click('[data-delres="2026-11-18"]'); await msgIs(p, /Létszám-bejegyzés törölve/);
  check(!T.th_residents.some(r => r.valid_from === '2026-11-18') && T.th_residents.length === 4, 'létszám: a véletlen bejegyzés törölve, a régi megmaradt');
  check(!(await p.$('#resetForm')) && !(await p.$('#importForm')), 'beállítások: nincs kiürítés és betöltés');
  check(await p.$eval('#tabs [data-tab=settings]', e => !e.hidden && e.classList.contains('on')), 'kezelő: külön Beállítások fül, kijelölve');
  await shot(p, 'tarsashaz-beallitasok');

  check(p.errors.length === 0 && q.errors.length === 0, 'nincs JavaScript-hiba' + (p.errors.length + q.errors.length ? ': ' + [...p.errors, ...q.errors].join(' | ') : ''));
} catch (e) {
  failed++;
  console.log('  HIBA     ' + e.message);
} finally {
  await browser.close(); mock.close(); site.close();
}
console.log(failed ? `\n${failed} ellenőrzés elbukott.` : '\nMinden ellenőrzés rendben.');
process.exit(failed ? 1 : 0);
