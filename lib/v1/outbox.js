// Kimenő sor (outbox) offline működéshez.
//
// Minden helyi módosítás azonnal megjelenik a felületen, és egy műveletként a
// sorba kerül (localStorage). Ha van hálózat, a flush() sorrendben elküldi őket.
// Hálózati hibánál a sor megmarad, és a következő flush() folytatja.
//
//   import { createOutbox, isRetryable } from 'https://laszlobiri.com/lib/v1/outbox.js';
//   const outbox = createOutbox('app.outbox.v1');
//   outbox.enqueue({ t: 'patch', id, fields });
//   await outbox.flush(async op => { ... ha hiba, dobd el ... }, (op, err) => { ... eldobott művelet ... });
//
// A műveleteket a hívó értelmezi; a sor csak tárol, sorrendet tart és újrapróbál.
// A kezelőnek idempotensnek kell lennie: egy művelet többször is elmehet (pl. ha a
// válasz elveszett), ezért a létrehozás kliens által generált azonosítóval történik.
//
// Publikus szerződés: a createOutbox, isRetryable nevek és a fenti viselkedés nem
// változhat; törő változás csak lib/v2 alatt.

/** Hálózati vagy átmeneti hiba-e (ilyenkor a művelet a sorban marad). */
export function isRetryable(error) {
  if (!error) return false;
  if (error.retry === true) return true;
  if (error.name === 'TypeError' || error.name === 'AuthRetryableFetchError') return true;
  const status = Number(error.status ?? 0);
  if (status === 401 || status === 408 || status === 429 || status >= 500) return true;
  const code = String(error.code ?? '');
  if (code === 'PGRST301' || code === 'PGRST303') return true;   // lejárt / érvénytelen JWT: frissítés után újra
  if (code === '' && /fetch|network|load failed|timeout|abort/i.test(String(error.message ?? ''))) return true;
  return navigator.onLine === false;
}

export function createOutbox(key) {
  const read = () => {
    try { const v = JSON.parse(localStorage.getItem(key)); return Array.isArray(v) ? v : []; }
    catch { return []; }
  };
  const write = ops => {
    try { localStorage.setItem(key, JSON.stringify(ops)); } catch { /* betelt tárhely: marad a memóriában lévő állapot */ }
  };

  return {
    /** A még el nem küldött műveletek, sorrendben. */
    pending: read,

    /** A várakozó műveletek száma. */
    size: () => read().length,

    /** Új művelet a sor végére. */
    enqueue(op) {
      const ops = read();
      ops.push({ ...op, qid: crypto.randomUUID(), at: Date.now() });
      write(ops);
    },

    /** A sorban lévő műveletek átírása (pl. azonosító cseréje); null-t visszaadva törlődik. */
    rewrite(fn) {
      write(read().map(fn).filter(Boolean));
    },

    /** A sor törlése (pl. felhasználóváltáskor). */
    clear() { write([]); },

    /**
     * A sor elküldése sorrendben. Eredmény: 'done' (üres a sor), 'offline' (hálózati
     * hiba, a maradék a sorban), vagy 'busy' (egy másik fül épp küld).
     * Nem átmeneti hibánál a művelet kikerül a sorból, és az onDrop(op, error) fut.
     */
    async flush(handle, onDrop) {
      const run = async () => {
        for (;;) {
          const op = read()[0];
          if (!op) return 'done';
          try {
            await handle(op);
          } catch (error) {
            if (isRetryable(error)) return 'offline';
            try { onDrop?.(op, error); } catch { /* a hívó hibája ne állítsa meg a sort */ }
          }
          // Újraolvasás: közben más is kerülhetett a sorba.
          write(read().filter(o => o.qid !== op.qid));
        }
      };
      // Egyszerre csak egy fül küldjön (ugyanazon az originen).
      if (navigator.locks?.request) {
        return navigator.locks.request('outbox:' + key, { ifAvailable: true }, lock => (lock ? run() : 'busy'));
      }
      return run();
    },
  };
}
