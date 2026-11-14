#!/usr/bin/env node
// Fekete dobozos ellenőrzés az éles (vagy teszt) Supabase-projekten, CSAK a
// nyilvános anon kulccsal: bejelentkezés nélkül semmilyen adat nem olvasható
// és nem írható, a private séma nem érhető el, és ismeretlen cím nem regisztrál.
//
// Futtatás:  npm run check:rls
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
const TABLES = ['profiles', 'households', 'household_members'];

let failed = 0;
const pass = msg => console.log('  rendben  ' + msg);
const fail = msg => { failed++; console.log('  HIBA     ' + msg); };

// Elutasítottnak számít: hiba, vagy üres eredmény (az RLS minden sort kiszűr).
async function expectNoRows(label, q) {
  const { data, error } = await q;
  if (error) return pass(`${label}: elutasítva (${error.code || error.message})`);
  if (Array.isArray(data) && data.length === 0) return pass(`${label}: üres`);
  fail(`${label}: ${Array.isArray(data) ? data.length + ' sor' : 'adat'} jött vissza`);
}
async function expectError(label, q) {
  const { error } = await q;
  if (error) return pass(`${label}: elutasítva (${error.code || error.message})`);
  fail(`${label}: sikerült, pedig nem szabadna`);
}

console.log('Bejelentkezés nélkül, anon kulccsal: ' + url);

for (const t of TABLES) {
  await expectNoRows(`select ${t}`, sb.from(t).select('*').limit(5));
  await expectError(`insert ${t}`, sb.from(t).insert({}));
  await expectNoRows(`update ${t}`, sb.from(t).update({ created_at: new Date().toISOString() }).not('created_at', 'is', null).select());
  await expectNoRows(`delete ${t}`, sb.from(t).delete().not('created_at', 'is', null).select());
}

await expectError('private séma (allowed_emails)', sb.schema('private').from('allowed_emails').select('*'));
await expectError('rpc hook_before_user_created', sb.rpc('hook_before_user_created', { event: {} }));

// Ismeretlen cím regisztrációja: az e-mail provider ki van kapcsolva, és az allowlist is elutasítja.
const probe = `rls-check-${Date.now()}@example.invalid`;
{
  const { data, error } = await sb.auth.signUp({ email: probe, password: crypto.randomUUID() });
  if (error || !data?.user) pass(`regisztráció ismeretlen címmel: elutasítva (${error?.code || error?.message || 'nincs felhasználó'})`);
  else fail('regisztráció ismeretlen címmel: létrejött egy felhasználó (' + probe + '), töröld a dashboardon');
}

console.log(failed ? `\n${failed} ellenőrzés elbukott.` : '\nMinden ellenőrzés rendben.');
process.exit(failed ? 1 : 0);
