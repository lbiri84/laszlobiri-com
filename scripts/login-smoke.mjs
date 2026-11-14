#!/usr/bin/env node
// A belépőoldal és a lib/v1 füstpróbája böngészőben, valódi Supabase nélkül.
//
// Egy helyi szerver kiszolgálja a repót, és ugyanazon az originen egy ál-Supabase
// végpontot is (auth/v1, rest/v1). A lib/v1/config.js helyett tesztkonfigurációt ad.
// Ellenőrzi: a Google-belépés helyes címre indul (PKCE), a visszatérő ?code=
// munkamenetté alakul és sütibe kerül, a ?next= csak laszlobiri/helyi címre
// irányít, az <lb-auth> a nevet mutatja, a kilépés törli a sütit, és az
// allowlist-elutasítás magyar üzenetet ad.
//
// Futtatás: node scripts/login-smoke.mjs   (Playwright + Chromium kell hozzá)

import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const PORT = 8765;
const ORIGIN = `http://localhost:${PORT}`;
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };

const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const USER = { id: '11111111-1111-1111-1111-111111111111', aud: 'authenticated', role: 'authenticated', email: 'szulo@example.invalid', user_metadata: { name: 'Teszt Szülő' }, app_metadata: { provider: 'google' } };
const now = () => Math.floor(Date.now() / 1000);
const session = () => ({
  access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: USER.id, role: 'authenticated', exp: now() + 3600, aud: 'authenticated', email: USER.email })}.sig`,
  // shortSession: azonnal lejáró access token (az offline kapu próbájához).
  token_type: 'bearer', expires_in: globalThis.shortSession ? 5 : 3600, expires_at: now() + (globalThis.shortSession ? 5 : 3600), refresh_token: 'refresh-test', user: USER,
});

const seen = [];
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, ORIGIN);
  seen.push(req.method + ' ' + u.pathname);
  if (u.pathname === '/lib/v1/config.js') {
    res.writeHead(200, { 'content-type': 'text/javascript' });
    return res.end(`export const SUPABASE_URL='${ORIGIN}';export const SUPABASE_ANON_KEY='anon-test';export const isConfigured=true;`);
  }
  if (u.pathname === '/auth/v1/authorize') {
    // A "Google" azonnal visszairányít a redirect_to címre egy kóddal (vagy hibával).
    const back = new URL(u.searchParams.get('redirect_to'));
    if (globalThis.rejectNext) {
      back.searchParams.set('error', 'access_denied');
      back.searchParams.set('error_description', 'Ez a cím nincs engedélyezve.');
    } else back.searchParams.set('code', 'test-code');
    res.writeHead(302, { location: back.href });
    return res.end();
  }
  if (u.pathname === '/auth/v1/token') {
    let body = ''; for await (const c of req) body += c;
    const j = JSON.parse(body || '{}');
    const ok = (u.searchParams.get('grant_type') === 'pkce' && j.auth_code === 'test-code' && j.code_verifier)
      || (u.searchParams.get('grant_type') === 'refresh_token' && j.refresh_token === 'refresh-test');
    if (ok) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify(session()));
    }
    res.writeHead(400, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ error: 'invalid_grant', error_description: 'bad code verifier' }));
  }
  if (u.pathname === '/auth/v1/user') {
    res.writeHead(200, { 'content-type': 'application/json' }); return res.end(JSON.stringify(USER));
  }
  if (u.pathname === '/auth/v1/logout') { res.writeHead(204); return res.end(); }
  if (u.pathname === '/rest/v1/profiles') {
    const row = { id: USER.id, display_name: 'Teszt Szülő', app_role: 'admin' };
    const single = /object/.test(req.headers.accept || '');
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(single ? row : [row]));
  }
  let file = path.join(ROOT, decodeURIComponent(u.pathname));
  if (!file.startsWith(ROOT)) { res.writeHead(403); return res.end(); }
  if (file.endsWith('/')) file += 'index.html';
  try {
    const data = await readFile(file);
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  } catch { res.writeHead(404); res.end('not found'); }
});
await new Promise(r => server.listen(PORT, r));

let failed = 0;
const check = (ok, msg) => { console.log((ok ? '  rendben  ' : '  HIBA     ') + msg); if (!ok) failed++; };

const browser = await chromium.launch();
const page = await browser.newPage();
const errors = [];
page.on('pageerror', e => errors.push(e.message));
// A szimulált hálózatkiesés (offline kapu próba) várt konzolüzenetét nem számoljuk hibának.
page.on('console', m => { if (m.type() === 'error' && !/ERR_INTERNET_DISCONNECTED/.test(m.text())) errors.push(m.text()); });

try {
  // A célnak egy helyi "aloldalt" használunk: egy oldal az <lb-auth> jelvénnyel.
  const target = `${ORIGIN}/scripts/fixtures/aloldal.html`;

  // Kapu: belépés nélkül a főoldal azonnal a belépőoldalra visz.
  await page.goto(`${ORIGIN}/`);
  await page.waitForURL(u => u.pathname === '/belepes/', { timeout: 10000 });
  check(new URL(page.url()).searchParams.get('next') === `${ORIGIN}/`, 'kapu: belépés nélkül a főoldal a belépőoldalra irányít (next = főoldal)');

  await page.goto(`${ORIGIN}/belepes/?next=${encodeURIComponent(target)}`);
  await page.waitForSelector('#google:not([hidden])', { state: 'visible' });
  check(await page.textContent('#status') === 'Lépj be a Google-fiókoddal.', 'kijelentkezve a Google gomb látszik');

  const authReq = page.waitForRequest(r => r.url().includes('/auth/v1/authorize'));
  await page.click('#google');
  const a = new URL((await authReq).url());
  check(a.searchParams.get('provider') === 'google', 'a belépés a Google providerrel indul');
  check(a.searchParams.get('code_challenge_method')?.toLowerCase() === 's256' && !!a.searchParams.get('code_challenge'), 'PKCE (S256) kódkihívás');
  check(new URL(a.searchParams.get('redirect_to')).pathname === '/belepes/', 'visszatérés a belépőoldalra');

  await page.waitForURL(target, { timeout: 10000 });
  check(true, 'sikeres belépés után a next címre irányít');
  const cookies = await page.context().cookies();
  const auth = cookies.filter(c => /auth-token/.test(c.name));
  check(auth.length > 0, 'a munkamenet sütiben van (' + auth.map(c => c.name).join(', ') + ')');
  check(auth.every(c => c.sameSite === 'Lax' && c.path === '/'), 'süti: SameSite=Lax, Path=/');

  await page.waitForFunction(() => document.querySelector('lb-auth')?.shadowRoot?.querySelector('.name')?.textContent === 'Teszt Szülő');
  check(true, '<lb-auth> a profil nevét mutatja');

  // Belépve a belépőoldal ?next nélkül a "Be vagy lépve" állapotot mutatja.
  await page.goto(`${ORIGIN}/belepes/`);
  await page.waitForSelector('#signedIn:not([hidden])');
  check((await page.textContent('#status')).includes('Teszt Szülő'), 'belépőoldal: "Be vagy lépve: Teszt Szülő."');

  // Kapu: belépve a főoldal látszik.
  await page.goto(`${ORIGIN}/`);
  await page.waitForFunction(() => !document.getElementById('lb-gate') && getComputedStyle(document.documentElement).visibility === 'visible');
  check(new URL(page.url()).pathname === '/', 'kapu: belépve a főoldal megjelenik');

  // Kilépés az aloldalon.
  await page.goto(target);
  await page.waitForFunction(() => document.querySelector('lb-auth')?.shadowRoot?.querySelector('button')?.textContent === 'Kilépés');
  await page.evaluate(() => document.querySelector('lb-auth').shadowRoot.querySelector('button').click());
  await page.waitForFunction(() => document.querySelector('lb-auth').shadowRoot.querySelector('button').textContent === 'Belépés');
  const left = (await page.context().cookies()).filter(c => /auth-token/.test(c.name));
  check(left.length === 0, 'kilépés után nincs munkamenet-süti');

  // Kapu offline, lejárt access tokennel: nem léptet ki.
  globalThis.shortSession = true;
  await page.goto(`${ORIGIN}/belepes/?next=${encodeURIComponent(ORIGIN + '/')}`);
  await page.click('#google');
  await page.waitForURL(`${ORIGIN}/`, { timeout: 10000 });
  await page.route('**/auth/v1/**', r => r.abort('internetdisconnected'));
  await page.goto(`${ORIGIN}/`);
  await page.waitForFunction(() => !document.getElementById('lb-gate'), null, { timeout: 10000 });
  check(new URL(page.url()).pathname === '/', 'kapu: offline, lejárt tokennel is megnyílik a főoldal');
  await page.unroute('**/auth/v1/**');
  globalThis.shortSession = false;

  // Kapu: kilépés a főoldalon a belépőoldalra visz.
  await page.goto(`${ORIGIN}/`);
  await page.waitForFunction(() => document.querySelector('lb-auth')?.shadowRoot?.querySelector('button')?.textContent === 'Kilépés');
  await page.evaluate(() => document.querySelector('lb-auth').shadowRoot.querySelector('button').click());
  await page.waitForURL(u => u.pathname === '/belepes/', { timeout: 10000 });
  check(true, 'kapu: kilépés után a belépőoldalra irányít');

  // Nyitott átirányítás: idegen next a főoldalra esik vissza.
  const { safeNextResult } = await page.evaluate(async () => {
    const m = await import('/lib/v1/auth.js');
    return { safeNextResult: [m.safeNext('https://evil.example/'), m.safeNext('https://bevasarlas.laszlobiri.com/x'), m.safeNext('javascript:alert(1)'), m.safeNext('//evil.example/')] };
  });
  check(safeNextResult[0] === ORIGIN + '/', 'safeNext: idegen domain → főoldal');
  check(safeNextResult[1] === 'https://bevasarlas.laszlobiri.com/x', 'safeNext: aloldal megengedett');
  check(safeNextResult[2] === ORIGIN + '/' && safeNextResult[3] === ORIGIN + '/', 'safeNext: javascript: és //idegen → főoldal');

  // Allowlist-elutasítás.
  globalThis.rejectNext = true;
  await page.goto(`${ORIGIN}/belepes/?next=${encodeURIComponent(target)}`);
  await page.click('#google');
  await page.waitForFunction(() => document.querySelector('#status').dataset.kind === 'error');
  check(await page.textContent('#status') === 'Ez a cím nincs engedélyezve.', 'elutasított cím: magyar hibaüzenet');
  check(!page.url().includes('error'), 'a hibaparaméter eltűnik a címsorból');
  globalThis.rejectNext = false;

  check(errors.length === 0, 'nincs JavaScript-hiba' + (errors.length ? ': ' + errors.join(' | ') : ''));
} catch (e) {
  failed++;
  console.log('  HIBA     ' + e.message);
} finally {
  await browser.close();
  server.close();
}

console.log(failed ? `\n${failed} ellenőrzés elbukott.` : '\nMinden ellenőrzés rendben.');
process.exit(failed ? 1 : 0);
