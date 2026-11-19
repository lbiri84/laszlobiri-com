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
  if (/Saját magad/.test(s)) return s.replace(/^.*?(Saját magad[^.]*\.).*$/, '$1');
  if (/megjegyzés/i.test(s)) return 'A megjegyzés legfeljebb 80 karakter.';
  if (/Csak admin/.test(s)) return 'Ehhez admin jog kell.';
  if (/fetch|network/i.test(s)) return 'Nincs kapcsolat. Próbáld újra.';
  return 'Nem sikerült. Próbáld újra.';
}

const appBoxes = (name, on, dis = false) => SITES.map(s =>
  `<label class="chk${dis ? ' dis' : ''}"><input type="checkbox" name="${name}" value="${s.app}"${on.includes(s.app) ? ' checked' : ''}${dis ? ' disabled' : ''}> ${esc(s.name)}</label>`).join('');

const checked = (root, name) => [...root.querySelectorAll(`input[name="${name}"]:checked`)].map(i => i.value);

// A táblázat oszlopainak rövid neve.
// A társasház lakásai (nevek nélkül).
const FLATS = ['fsz-1', 'fsz-2', 'em-3', 'em-4'];

const SHORT = { ebed: 'Interfood', bevasarlas: 'Lista', gyakorlas: 'Gyakorló', tarsashaz: 'Társasház' };

function row(r, i) {
  const self = r.email === me;
  const who = r.has_account
    ? `${esc(r.display_name || 'Fiók')}, utoljára: ${r.last_sign_in_at ? esc(day(r.last_sign_in_at)) : 'még nem'}`
    : 'Még nem lépett be.';
  const box = (name, val, on, label, dis = false) =>
    `<td class="c"><input type="checkbox" name="${name}" value="${val}"${on ? ' checked' : ''}${dis ? ' disabled' : ''} aria-label="${esc(r.email)}: ${esc(label)}"></td>`;
  return `<tr data-i="${i}">
  <td class="addr"><div class="email">${esc(r.email)}</div>${r.app_role === 'admin' || self ? `<div>${r.app_role === 'admin' ? '<span class="pill">admin</span>' : ''}${self ? '<span class="pill">te</span>' : ''}</div>` : ''}<div class="who">${who}</div></td>
  ${SITES.map(s => box('app', s.app, (r.apps || []).includes(s.app), SHORT[s.app] || s.name)).join('')}
  <td class="flat"><select name="flat" aria-label="${esc(r.email)}: lakás (társasház)"${(r.apps || []).includes('tarsashaz') ? '' : ' disabled'}>${['', ...FLATS].map(f => `<option value="${f}"${(r.flat || '') === f ? ' selected' : ''}>${f || '–'}</option>`).join('')}</select></td>
  <td class="note"><input type="text" name="note" maxlength="80" value="${esc(r.note)}" aria-label="${esc(r.email)}: megjegyzés"></td>
  <td class="act"><button class="danger" type="button" data-remove${self ? ' disabled' : ''}>Visszavonás</button></td>
</tr>`;
}

function render() {
  $('count').textContent = `(${rows.length})`;
  $('head').innerHTML = '<th>Cím</th>' + SITES.map(s => `<th>${esc(SHORT[s.app] || s.name)}</th>`).join('')
    + '<th>Lakás</th><th>Megjegyzés</th><th></th>';
  $('list').innerHTML = rows.map(row).join('');
}

async function load() {
  const { data, error } = await supabase.rpc('admin_access_list');
  if (error) throw error;
  rows = data || [];
  render();
}

async function save(email, apps, note) {
  const { error } = await supabase.rpc('admin_access_set', { p_email: email, p_apps: apps, p_note: note || null });
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
      await save(email, apps, $('addNote').value.trim());
      f.reset();
      await load();
      say(`Hozzáadva: ${email}. Most már beléphet a Google-fiókjával.`);
    } catch (err) { say(errText(err), 'error'); }
    finally { f.querySelector('button').disabled = false; }
  });

  // Pipa vagy megjegyzés változása: a sor azonnal mentődik (a megjegyzés kilépéskor vagy Enterre).
  $('list').addEventListener('change', async e => {
    const tr = e.target.closest('tr');
    if (!tr || tr.classList.contains('busy')) return;
    const r = rows[+tr.dataset.i];
    const note = tr.querySelector('input[name=note]').value.trim();
    tr.classList.add('busy');
    tr.querySelectorAll('input, select').forEach(i => { i.disabled = true; });
    try {
      if (e.target.name === 'flat') {
        const { error } = await supabase.rpc('admin_set_flat', { p_email: r.email, p_flat: e.target.value || null });
        if (error) throw error;
      } else await save(r.email, checked(tr, 'app'), note);
      await load();
      say(`Mentve: ${r.email}.`);
    } catch (err) {
      say(errText(err), 'error');
      try { await load(); } catch { /* az üzenet már ott van */ }
    }
  });
  $('list').addEventListener('keydown', e => { if (e.key === 'Enter' && e.target.name === 'note') e.target.blur(); });

  $('list').addEventListener('click', async e => {
    const b = e.target.closest('button[data-remove]');
    if (!b) return;
    const r = rows[+b.closest('tr').dataset.i];
    if (!confirm(`Visszavonod ${r.email} hozzáférését? A fiókja megmarad, de egyik oldalt sem nyithatja meg.`)) return;
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
