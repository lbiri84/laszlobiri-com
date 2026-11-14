// A központi belépőoldal: Google-belépés indítása, a visszatérés feldolgozása,
// majd visszairányítás a ?next= címre (csak laszlobiri oldalra, lásd safeNext).
import { isConfigured, getUser, getProfile, startGoogleLogin, completeLogin, signOut, safeNext } from '/lib/v1/auth.js';

const $ = id => document.getElementById(id);
const params = new URLSearchParams(location.search);
const rawNext = params.get('next');
const next = safeNext(rawNext);

function status(text, kind) {
  $('status').textContent = text;
  if (kind) $('status').dataset.kind = kind; else delete $('status').dataset.kind;
}
function show(state) {
  $('signedOut').hidden = state !== 'out';
  $('signedOutNote').hidden = state !== 'out';
  $('signedIn').hidden = state !== 'in';
  $('apps').hidden = state !== 'in' || Boolean(rawNext);
}

async function showSignedIn() {
  const p = await getProfile();
  const u = await getUser();
  status('Be vagy lépve' + (p?.display_name || u?.email ? ': ' + (p?.display_name || u.email) : '') + '.');
  $('continue').href = next;
  $('continue').hidden = !rawNext;
  show('in');
}

async function main() {
  if (!isConfigured) { status('A belépés még nincs beállítva.'); return; }

  const r = await completeLogin();
  if (r.status === 'error') { status(r.message, 'error'); show('out'); return; }
  if (r.status === 'signed-in' && rawNext) { status('Sikeres belépés, továbbítás…'); location.replace(next); return; }

  if (await getUser()) {
    if (rawNext && r.status === 'none') { location.replace(next); return; }
    await showSignedIn();
  } else {
    status('Lépj be a Google-fiókoddal.');
    show('out');
  }
}

$('google').addEventListener('click', async () => {
  $('google').disabled = true;
  status('Átirányítás a Google-höz…');
  try { await startGoogleLogin(next); }
  catch { $('google').disabled = false; status('A belépés nem indult el. Próbáld újra.', 'error'); }
});

$('signout').addEventListener('click', async () => {
  await signOut();
  status('Kiléptél. Ez minden laszlobiri oldalra érvényes.');
  show('out');
});

main();
