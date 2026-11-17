// Hozzáférések kezelése (laszlobiri.com/admin/): csak admin.
//
// Minden művelet az adatbázis admin függvényein megy (admin_access_list / _set / _remove),
// amelyek maguk is ellenőrzik, hogy a hívó admin. Ez az oldal csak a felület.

import { ready } from '/lib/v1/gate.js';
import { supabase } from '/lib/v1/client.js';
import { SITES, getAccess } from '/lib/v1/access.js';

const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const day = t => t ? new Date(t).toLocaleDateString('hu-HU', { year: 'numeric', month: 'long', day: 'numeric' }) : '';

let me = '';     // a belépett admin e-mail címe (kisbetűvel)
let rows = [];

function say(text, kind = '') { const m = $('msg'); m.textContent = text; m.dataset.kind = kind; }

function errText(e) {
  const s = String(e?.message || e || '');
  if (/Érvénytelen e-mail/.test(s)) return 'Érvénytelen e-mail cím.';
  if (/Saját magadat/.test(s)) return s.replace(/^.*?(Saját magadat[^.]*\.).*$/, '$1');
  if (/megjegyzés/i.test(s)) return 'A megjegyzés legfeljebb 80 karakter.';
  if (/Csak admin/.test(s)) return 'Ehhez admin jog kell.';
  if (/fetch|network/i.test(s)) return 'Nincs kapcsolat. Próbáld újra.';
  return 'Nem sikerült. Próbáld újra.';
}

const appBoxes = (name, on, dis = false) => SITES.map(s =>
  `<label class="chk${dis ? ' dis' : ''}"><input type="checkbox" name="${name}" value="${s.app}"${on.includes(s.app) ? ' checked' : ''}${dis ? ' disabled' : ''}> ${esc(s.name)}${s.soon ? ' <span class="soon">(készül)</span>' : ''}</label>`).join('');

const checked = (root, name) => [...root.querySelectorAll(`input[name="${name}"]:checked`)].map(i => i.value);

function card(r, i) {
  const self = r.email === me;
  const who = r.has_account
    ? `${esc(r.display_name || 'Fiók')}, utoljára belépett: ${r.last_sign_in_at ? esc(day(r.last_sign_in_at)) : 'még nem'}`
    : 'Még nem lépett be.';
  return `<form class="card" data-i="${i}" novalidate>
  <div class="email">${esc(r.email)}${r.app_role === 'admin' ? '<span class="pill">admin</span>' : ''}${self ? '<span class="pill">te</span>' : ''}</div>
  <p class="who">${who}</p>
  <fieldset><legend>Oldalak</legend><div class="checks">${appBoxes('app', r.apps || [])}</div></fieldset>
  <fieldset><legend>Család</legend><div class="checks"><label class="chk${self ? ' dis' : ''}"><input type="checkbox" name="hh"${r.in_household ? ' checked' : ''}${self ? ' disabled' : ''}> Családtag</label></div></fieldset>
  <label class="field"><span>Megjegyzés</span><input type="text" name="note" maxlength="80" value="${esc(r.note)}"></label>
  <div class="row"><button class="primary" type="submit" disabled>Mentés</button><button class="danger" type="button" data-remove${self ? ' disabled' : ''}>Visszavonás</button></div>
</form>`;
}

function render() {
  $('count').textContent = `(${rows.length})`;
  $('list').innerHTML = rows.map(card).join('');
}

async function load() {
  const { data, error } = await supabase.rpc('admin_access_list');
  if (error) throw error;
  rows = data || [];
  render();
}

async function save(email, apps, household, note) {
  const { error } = await supabase.rpc('admin_access_set', { p_email: email, p_apps: apps, p_household: household, p_note: note || null });
  if (error) throw error;
}

async function init() {
  const { user } = await ready;
  if (!user) { say('Nincs kapcsolat. Az oldal csak online használható.', 'error'); return; }
  me = String(user.email || '').toLowerCase();
  let access;
  try { access = await getAccess(user.id, { timeoutMs: 8000 }); } catch (e) { say(errText(e), 'error'); return; }
  if (!access.admin) { say('Ez az oldal csak adminnak érhető el.', 'error'); return; }

  $('addApps').innerHTML = appBoxes('app', []);
  try { await load(); } catch (e) { say(errText(e), 'error'); return; }
  $('admin').hidden = false;
  say('');

  $('add').addEventListener('submit', async e => {
    e.preventDefault();
    const f = e.currentTarget, email = $('addEmail').value.trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { say('Érvénytelen e-mail cím.', 'error'); $('addEmail').focus(); return; }
    const apps = checked(f, 'app');
    if (rows.some(r => r.email === email) && !confirm(`${email} már a listában van. Felülírod a beállításait?`)) return;
    f.querySelector('button').disabled = true;
    try {
      await save(email, apps, $('addHh').checked, $('addNote').value.trim());
      f.reset();
      await load();
      say(`Hozzáadva: ${email}. Most már beléphet a Google-fiókjával.`);
    } catch (err) { say(errText(err), 'error'); }
    finally { f.querySelector('button').disabled = false; }
  });

  // Változáskor a Mentés gomb aktív lesz.
  $('list').addEventListener('input', e => { const f = e.target.closest('form'); if (f) f.querySelector('button[type=submit]').disabled = false; });

  $('list').addEventListener('submit', async e => {
    e.preventDefault();
    const f = e.target, r = rows[+f.dataset.i], btn = f.querySelector('button[type=submit]');
    const hh = f.querySelector('input[name=hh]');
    btn.disabled = true;
    try {
      await save(r.email, checked(f, 'app'), hh.disabled ? r.in_household : hh.checked, f.querySelector('input[name=note]').value.trim());
      await load();
      say(`Mentve: ${r.email}.`);
    } catch (err) { btn.disabled = false; say(errText(err), 'error'); }
  });

  $('list').addEventListener('click', async e => {
    const b = e.target.closest('button[data-remove]');
    if (!b) return;
    const r = rows[+b.closest('form').dataset.i];
    if (!confirm(`Visszavonod ${r.email} hozzáférését? A fiókja megmarad, de egyik oldalt sem nyithatja meg, és kikerül a családból.`)) return;
    b.disabled = true;
    try {
      const { error } = await supabase.rpc('admin_access_remove', { p_email: r.email });
      if (error) throw error;
      await load();
      say(`Visszavonva: ${r.email}.`);
    } catch (err) { b.disabled = false; say(errText(err), 'error'); }
  });
}

init();
