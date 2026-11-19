#!/usr/bin/env node
// Fekete dobozos ellenőrzés az éles (vagy teszt) Supabase-projekten, CSAK a
// nyilvános anon kulccsal: bejelentkezés nélkül semmilyen adat nem olvasható
// és nem írható, a private séma nem érhető el, és ismeretlen cím nem regisztrál.
//
// Futtatás:  npm run check:rls
// (HTTPS-proxy mögött: NODE_USE_ENV_PROXY=1 npm run check:rls, Node 22.21+.)
// A projekt adatait a lib/v1/config.js-ből veszi, vagy a SUPABASE_URL és
// SUPABASE_ANON_KEY környezeti változóból. Service kulcs nem kell, és ne is add meg.
//
// Kilépési kód: 0 = minden rendben, 1 = legalább egy ellenőrzés elbukott.

import { createClient } from '@supabase/supabase-js';

const cfg = await import(new URL('../lib/v1/config.js', import.meta.url));
const url = process.env.SUPABASE_URL || cfg.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY || cfg.SUPABASE_ANON_KEY;
if (!url || !key) {
  console.error('Hiányzik a projekt URL vagy az anon kulcs (lib/v1/config.js vagy környezeti változó).');
  process.exit(2);
}
if (/service_role|sb_secret_/.test(key) || (() => {
  try { return JSON.parse(Buffer.from(key.split('.')[1], 'base64url')).role === 'service_role'; } catch { return false; }
})()) {
  console.error('Ez service kulcsnak látszik. Ehhez a teszthez csak az anon (publishable) kulcs használható.');
  process.exit(2);
}

const sb = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

// Minden public tábla, amit a migrációk létrehoznak. Új táblánál ide is fel kell venni.
// A második érték egy létező oszlop a módosítás-próbához (PostgREST előbb az oszlopot ellenőrzi).
const TABLES = {
  profiles: 'display_name', households: 'name', household_members: 'role',
  lists: 'name', items: 'name', item_history: 'name',
  pupils: 'nickname', results: 'topic', pupil_badges: 'badge_id', devices: 'label', question_reports: 'prompt', chapter_access: 'subject',
  device_pupils: null,   // nincs szöveges oszlopa: csak olvasás és beszúrás
  th_flats: 'code', th_residents: 'flat', th_periods: 'name', th_readings: 'note', th_items: 'name', th_item_shares: 'flat', th_transfers: 'from_flat',
};

let failed = 0;
const pass = msg => console.log('  rendben  ' + msg);
const fail = msg => { failed++; console.log('  HIBA     ' + msg); };
let warned = 0;
const warn = msg => { warned++; console.log('  FIGYELEM ' + msg); };

// Csak a jogosultsági elutasítás számít sikernek. Hálózati hiba vagy hiányzó
// tábla NEM: az nem bizonyítja, hogy az RLS véd.
const DENIED = new Set(['42501', 'PGRST301', 'PGRST302']);      // nincs jog / RLS / nincs JWT
const MISSING = new Set(['PGRST205', '42P01', 'PGRST204']);      // tábla vagy oszlop nem létezik

function classify(error) {
  const code = error?.code || '';
  if (DENIED.has(code)) return 'denied';
  if (MISSING.has(code)) return 'missing';
  if (!code || /fetch failed|network|ECONN|ENOTFOUND/i.test(error?.message || '')) return 'network';
  return 'other';
}
function report(label, error, extraOk = []) {
  const kind = classify(error);
  const tag = `${error.code || '-'}: ${error.message}`;
  if (kind === 'denied' || extraOk.includes(error.code)) return pass(`${label}: elutasítva (${tag})`);
  if (kind === 'missing') return fail(`${label}: a tábla nem létezik — lefutott a migráció? (${tag})`);
  if (kind === 'network') return fail(`${label}: a projekt nem érhető el (${tag})`);
  fail(`${label}: váratlan hiba (${tag})`);
}

// Elutasítva, vagy üres eredmény (az RLS minden sort kiszűr).
async function expectNoRows(label, q) {
  const { data, error } = await q;
  if (error) return report(label, error);
  if (Array.isArray(data) && data.length === 0) return pass(`${label}: üres`);
  fail(`${label}: ${Array.isArray(data) ? data.length + ' sor' : 'adat'} jött vissza`);
}
async function expectError(label, q, extraOk = []) {
  const { error } = await q;
  if (error) return report(label, error, extraOk);
  fail(`${label}: sikerült, pedig nem szabadna`);
}

// Előbb: elérhető-e a projekt egyáltalán.
try {
  const r = await fetch(url + '/auth/v1/health', { headers: { apikey: key } });
  if (!r.ok) { console.error(`A projekt nem válaszol rendesen: HTTP ${r.status}`); process.exit(2); }
} catch (e) {
  console.error('A projekt nem érhető el: ' + (e.cause?.message || e.message));
  process.exit(2);
}

console.log('Bejelentkezés nélkül, anon kulccsal: ' + url);

for (const [t, col] of Object.entries(TABLES)) {
  await expectNoRows(`select ${t}`, sb.from(t).select('*').limit(5));
  await expectError(`insert ${t}`, sb.from(t).insert({}));
  if (!col) continue;
  await expectNoRows(`update ${t}`, sb.from(t).update({ [col]: 'rls-check' }).not(col, 'is', null).select());
  await expectNoRows(`delete ${t}`, sb.from(t).delete().not(col, 'is', null).select());
}
await expectError('rpc create_pairing', sb.rpc('create_pairing', { p_pupils: ['00000000-0000-0000-0000-000000000000'], p_label: 'x' }));
await expectError('rpc claim_pairing', sb.rpc('claim_pairing', { p_code: 'AAAA-AAAA' }));
await expectError('rpc my_access', sb.rpc('my_access'));
await expectError('rpc admin_access_list', sb.rpc('admin_access_list'));
await expectError('rpc admin_access_set', sb.rpc('admin_access_set', { p_email: 'x@example.invalid', p_apps: ['ebed'] }));
await expectError('rpc admin_access_remove', sb.rpc('admin_access_remove', { p_email: 'x@example.invalid' }));
await expectError('rpc admin_set_flat', sb.rpc('admin_set_flat', { p_email: 'x@example.invalid', p_flat: 'em-4' }));
await expectError('rpc th_me', sb.rpc('th_me'));
await expectError('rpc th_open_period', sb.rpc('th_open_period', { p_name: 'x', p_starts_on: '2026-01-01' }));
await expectError('rpc th_save_item', sb.rpc('th_save_item', { p: {} }));
await expectError('rpc th_save_flats', sb.rpc('th_save_flats', { p: {} }));
await expectError('rpc th_mark_transfer', sb.rpc('th_mark_transfer', { p_id: '00000000-0000-0000-0000-000000000000', p_paid: true }));
await expectError('rpc th_delete_period', sb.rpc('th_delete_period', { p_id: '00000000-0000-0000-0000-000000000000', p_force: true }));
await expectError('rpc th_rename_period', sb.rpc('th_rename_period', { p_id: '00000000-0000-0000-0000-000000000000', p_name: 'x', p_starts_on: '2026-01-01', p_ends_on: null, p_note: null }));
await expectError('rpc th_delete_residents', sb.rpc('th_delete_residents', { p_valid_from: '2026-01-01' }));
await expectError('rpc bump_history', sb.rpc('bump_history', {
  p_household: '00000000-0000-0000-0000-000000000000', p_name_key: 'x', p_name: 'x', p_cat: 'egyeb',
}));

// PGRST106: a séma nincs közzétéve a Data API-n.
await expectError('private séma (allowed_emails)', sb.schema('private').from('allowed_emails').select('*'), ['PGRST106']);
// PGRST202: a public sémában nincs ilyen függvény (a hook a private sémában van).
await expectError('rpc hook_before_user_created', sb.rpc('hook_before_user_created', { event: {} }), ['PGRST202']);

// Ismeretlen cím regisztrációja: az e-mail provider ki van kapcsolva, és az allowlist is elutasítja.
// example.com: foglalt tartomány, valódi postafiók nincs mögötte.
const probe = `rls-check-${Date.now()}@example.com`;
{
  const { data, error } = await sb.auth.signUp({ email: probe, password: crypto.randomUUID() });
  const tag = error ? `${error.code || error.status}: ${error.message}` : '';
  if (!error && data?.user) fail('regisztráció ismeretlen címmel: létrejött egy felhasználó (' + probe + '), töröld a dashboardon');
  else if (!error) fail('regisztráció ismeretlen címmel: nem jött hiba, de felhasználó sem; ellenőrizd a dashboardon');
  else if (['email_provider_disabled', 'signup_disabled'].includes(error.code)) pass(`regisztráció e-maillel: az e-mail provider ki van kapcsolva (${tag})`);
  else if (/nincs engedélyezve|hook/i.test(error.message)) {
    pass(`regisztráció e-maillel: az allowlist hook elutasította (${tag})`);
    warn('az e-mail provider be van kapcsolva; csak Google-belépés kell, kapcsold ki (Authentication → Providers → Email)');
  } else if (/database error saving new user/i.test(error.message)) {
    pass(`regisztráció e-maillel: az allowlist trigger elutasította (${tag})`);
    warn('az e-mail provider be van kapcsolva; kapcsold ki (Authentication → Providers → Email)');
    warn('a Before User Created hook nem utasított el, tehát nincs bekötve (Authentication → Hooks); most csak a trigger véd');
  }
  else if (error.status === 0 || /fetch/i.test(error.message)) fail(`regisztráció: a projekt nem érhető el (${tag})`);
  else fail(`regisztráció: nem egyértelmű elutasítás, ellenőrizd az e-mail providert (${tag})`);
}

console.log(failed ? `\n${failed} ellenőrzés elbukott.` : '\nMinden ellenőrzés rendben.' + (warned ? ` ${warned} figyelmeztetés (beállítás, nem adatszivárgás).` : ''));
process.exit(failed ? 1 : 0);
