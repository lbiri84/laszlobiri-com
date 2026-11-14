// <lb-auth>: kis belépés/kilépés jelvény a laszlobiri oldalakra.
//
//   <script type="module" src="https://laszlobiri.com/lib/v1/auth-badge.js"></script>
//   <lb-auth></lb-auth>
//
// Kijelentkezve „Belépés” gomb, belépve a név és „Kilépés”. Ha a lib/v1 még
// nincs beállítva (config.js üres), semmit nem jelenít meg.
// A színek a tokens.css változóiból jönnek (a CSS-változók átjutnak a shadow DOM-on).

import { isConfigured, onAuthChange, getProfile, signIn, signOut } from './auth.js';

const css = `
  :host { display: inline-flex; align-items: center; gap: var(--space-2, 8px);
          font: 500 14px/20px var(--font-sans, system-ui, sans-serif); color: var(--fg-muted); }
  :host([hidden]) { display: none; }
  .name { color: var(--fg); max-width: 16ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  button { font: inherit; color: var(--accent-text); background: transparent; cursor: pointer;
           border: 1px solid var(--line); border-radius: var(--radius-full, 9999px);
           padding: 2px var(--space-3, 12px); min-height: 32px; }
  button:hover { border-color: var(--accent-text); }
  button:focus-visible { outline: 2px solid var(--fg); outline-offset: 2px; }
`;

class LbAuth extends HTMLElement {
  connectedCallback() {
    if (!isConfigured) { this.hidden = true; return; }
    if (this.shadowRoot) return;
    const root = this.attachShadow({ mode: 'open' });
    const style = document.createElement('style');
    style.textContent = css;
    this.nameEl = document.createElement('span');
    this.nameEl.className = 'name';
    this.btn = document.createElement('button');
    this.btn.type = 'button';
    this.btn.addEventListener('click', () => this.onClick());
    root.append(style, this.nameEl, this.btn);
    this.render(null);
    this.off = onAuthChange(user => this.update(user));
  }

  disconnectedCallback() { this.off?.(); this.off = null; }

  async update(user) {
    this.user = user;
    if (!user) return this.render(null);
    const p = await getProfile();
    this.render(p?.display_name || user.user_metadata?.name || user.email || 'Belépve');
  }

  render(name) {
    this.nameEl.textContent = name || '';
    this.nameEl.hidden = !name;
    this.btn.textContent = name ? 'Kilépés' : 'Belépés';
  }

  async onClick() {
    if (!this.user) return signIn(this.getAttribute('next') || location.href);
    this.btn.disabled = true;
    try { await signOut(); } finally { this.btn.disabled = false; }
  }
}

if (!customElements.get('lb-auth')) customElements.define('lb-auth', LbAuth);
