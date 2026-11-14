#!/usr/bin/env bash
# A migrációk és a pgTAP tesztek futtatása egy ideiglenes, helyi Postgresen,
# Docker és Supabase nélkül. A Supabase-specifikus sémákat és szerepeket a
# supabase/tests/stub/supabase-stub.sql utánozza.
#
# Kell hozzá: Postgres (initdb, pg_ctl, psql) és a pgTAP bővítmény
# (Debian/Ubuntu: postgresql-16-pgtap). Teljes Supabase-környezetben
# ugyanezek a tesztek `supabase test db` paranccsal is futnak.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
PATH="$PGBIN:$PATH"

TMP="$(mktemp -d)"
PORT="${PGPORT_TEST:-54329}"
cleanup() { pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

RUN_AS=()
if [ "$(id -u)" = "0" ]; then
  # initdb nem fut rootként: egy külön felhasználóval indítjuk.
  id pgtest >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin pgtest
  chown -R pgtest "$TMP"
  RUN_AS=(runuser -u pgtest --)
fi

"${RUN_AS[@]}" initdb -D "$TMP/data" -U postgres -A trust >/dev/null
"${RUN_AS[@]}" pg_ctl -D "$TMP/data" -o "-p $PORT -k $TMP -c listen_addresses=''" -l "$TMP/log" -w start >/dev/null

PSQL=(psql -h "$TMP" -p "$PORT" -U postgres -d postgres -X -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" -f "$ROOT/supabase/tests/stub/supabase-stub.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "migráció: $(basename "$f")"
  "${PSQL[@]}" -f "$f"
done

fail=0
for f in "$ROOT"/supabase/tests/*.test.sql; do
  out="$("${PSQL[@]}" -t -A -f "$f" 2>&1)" || { echo "$out"; fail=1; continue; }
  echo "$out" | grep -E '^(not ok|ok|#)' | sed 's/^/  /'
  if echo "$out" | grep -qE '^not ok|^# Looks like'; then fail=1; fi
  echo "teszt: $(basename "$f") $( [ $fail = 0 ] && echo rendben || echo HIBA )"
done

exit $fail
