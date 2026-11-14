# Backend: a laszlobiri oldalak közös háttere

Állapot (2026-11-14): **élesben.** A főoldal, az `ebed.`, a `bevasarlas.` és a `gyakorlas.` csak belépve használható; a bevásárlólista a háztartás közös listája, a gyakorló gyerekprofilokkal, közös eredményekkel és gyerek móddal működik. Hátravan: mentés és export (lásd „Hátralévő munka”).

A kézi beállítások (Supabase, Google, migrációk, új felhasználó) a [`supabase/README.md`](../supabase/README.md)-ben vannak.

## Áttekintés

- **Frontend**: statikus oldalak GitHub Pages-en, négy repóban. Build nincs; a közös kód a `laszlobiri.com/lib/v1/` címről töltődik.
- **Backend**: egy közös Supabase-projekt (`eokwxkrcttsoxfflvuus`, EU, Frankfurt): Google OAuth, Postgres, Row Level Security (RLS), Realtime, `pg_cron`.
- **Védelem**: minden adatot az adatbázis RLS-e véd. Az oldalak kapuja böngészőben működik: a fájlok és a repók nyilvánosak, adat nélkül viszont üresek.

| repó | cím | közzététel | backend |
| --- | --- | --- | --- |
| `laszlobiri-com` | `laszlobiri.com` | Pages, ágból (Jekyll, `_config.yml` kizárja a `docs/`, `supabase/`, `scripts/` mappát) | design system, `lib/v1`, `/belepes/`, `/adatvedelem/`, migrációk, tesztek |
| `interfood-menu` | `ebed.laszlobiri.com` | Actions (`update-menu.yml`) | csak a kapu |
| `bevasarlo-lista` | `bevasarlas.laszlobiri.com` | Pages, ágból | közös lista, offline kimenő sor, Realtime |
| `gyakorlas` | `gyakorlas.laszlobiri.com` | Pages, ágból | gyerekprofilok, eredmények, gyerek mód, hibás feladat jelentése |

### Fix feltételek

| feltétel | hogyan teljesül |
| --- | --- |
| DNS és Proton Mail rekordok nem változnak, nincs nameserver-váltás | Nincs Supabase custom domain; az auth a `<ref>.supabase.co` címen fut. A meglévő aldomain CNAME-ek maradtak. |
| `tokens.css` útvonala és a változónevek érintetlenek | A közös kód a `lib/v1/` mappában van; a gyakorló rózsaszín témája az oldal saját CSS-ében írja felül a tokeneket. |
| csak a publikus kulcs és a projekt URL kerül kliensbe | `lib/v1/config.js`; a service role / secret kulcs semmilyen repóban és kliensben nincs. |
| gyerekekről csak becenév és eredmény | `pupils`: becenév, ikon, színtéma; `results` / `pupil_badges` / `question_reports`: kódok, számok és a generált kérdés szövege, szabad szöveg nélkül. A gyereknek nincs fiókja. |
| a bevásárlólista offline is működik | Helyi másolat és kimenő sor a telefonon; visszatérő hálózatnál szinkron. |

## Belépés

1. Minden védett oldal a központi `https://laszlobiri.com/belepes/?next=…` oldalra küld. A `next` csak a négy laszlobiri cím lehet (nyitott átirányítás ellen).
2. Google-belépés PKCE-vel, csak `openid email profile` scope.
3. **Allowlist két rétegben**: a „Before User Created” hook (`private.hook_before_user_created`) elutasítja az ismeretlen címet (403, „Ez a cím nincs engedélyezve.”); a `auth.users` triggere (`private.handle_new_user`) akkor is elutasít, ha a hook nincs bekötve. A trigger hozza létre a profilt és a háztartás-tagságot. Névtelen fiókot (gyerek tablet) mindkettő átenged, profil nélkül.
4. **Közös munkamenet**: süti `Domain=.laszlobiri.com; Secure; SameSite=Lax` (`@supabase/ssr`), így egy belépés mind a négy címen érvényes, és a kilépés is mindenhol kiléptet.
5. Ki van kapcsolva: e-mail/jelszó, magic link. Be van kapcsolva: Google és a névtelen belépés (a gyerek módhoz, alacsony rate limittel).

### Belépési kapu

- Minden oldal `<head>`-jének elején: rejtett oldal (`lb-gate` stílus), egy beágyazott sor, ami munkamenet-süti híján **rajzolás előtt** a belépőoldalra irányít, és a `lib/v1/gate.js`, ami a helyi munkamenetet ellenőrzi, majd megjeleníti az oldalt.
- Offline is megnyit: ha a böngésző offline, vagy a munkamenet 3 másodpercen belül nem áll elő (lejárt token, nincs hálózat), de van munkamenet-süti. Kiléptetni csak a szerver egyértelmű elutasítása léptet ki, hálózati hiba soha.
- A gyakorló kapuja a párosított gyerek tabletet (`localStorage['lb-device']`) és a párosító oldalt (`#parositas`) is átengedi.
- Kivétel: `/belepes/` és `/adatvedelem/` nyilvános.

### Ismert korlátok

- Safari (ITP) a JavaScriptből írt sütit legfeljebb 7 napig tartja meg; minden frissítés újraírja, tehát csak egy hét teljes kihagyás után kell újra belépni.
- iOS-en a kezdőképernyőre tett appnak külön tárolója van: ott egyszer külön kell belépni, illetve a gyerek tabletet a telepített appban kell párosítani. Ha a tableten Safariban is volt szülői belépés, ott ki kell lépni.
- Két aloldal egyszerre frissítheti a tokent; ezt a refresh token reuse interval kezeli.

## Adatmodell és jogok

| tábla | tartalom | ki olvassa | ki írja |
| --- | --- | --- | --- |
| `private.allowed_emails` | engedélyezett címek, háztartás, szerep | senki (nincs közzétéve) | admin SQL |
| `profiles` | név, `app_role` | saját + a háztartás tagjai | saját név (`display_name`); a többit a trigger |
| `households`, `household_members` | háztartás, tagság (`parent`) | tagok | név: szülő; tagság: trigger / admin SQL |
| `lists` | háztartásonként egy lista (trigger hozza létre) | tagok | név: tagok |
| `items` | tétel (`name_key` egyedi az élő tételek között, soft delete) | tagok | tagok; `created_by`, `updated_*`, `list_id` a szerveré; valódi törlés nincs |
| `item_history` | „gyakran vett” javaslatok | tagok | csak `bump_history()` |
| `pupils` | becenév, ikon, `theme` (`slate` / `rose` / `sky`) | szülő; a tablet a hozzá rendelteket | szülő; a tablet csak a hozzá rendelt gyerek `theme`-jét (`pupils_guard`) |
| `results` | befejezett kör / minijáték-győzelem (`round`, `hangman`, `wordsearch`, `breakout`; csak hozzáfűzés) | szülő; a tablet a hozzá rendelteket | szülő / tablet; `recorded_by` a szerveré; törölni csak a szülő |
| `pupil_badges` | jelvények | mint `results` | mint `results` |
| `devices`, `device_pupils` | párosított gyerek tabletek | szülő; a tablet a sajátját | `claim_pairing()`; törlés (visszavonás): szülő |
| `private.device_pairings`, `private.pairing_attempts` | párosító kódok (hash), hibás próbálkozások | senki | `create_pairing()` / `claim_pairing()` |
| `question_reports` | hibás feladat jelentése (a kérdés pillanatképe, okkód) | csak a szülő | beküldés: szülő / a hozzá rendelt tablet; `status`: szülő |

- Az `anon` szerep egyik táblán sem kap jogot. A segédfüggvények (`private.is_member`, `is_parent`, `list_household`, `pupil_household`, `is_device_for`) `security definer`-ek.
- Párosítás: a kód 8 karakter, 10 percig él, egyszer használható; fiókonként 10 hibás próbálkozás után zár. A `claim_pairing` hibás kódnál nem kivételt dob, hanem `'invalid'`-ot ad, különben a számláló is visszagörgetődne.
- Napi takarítás (`pg_cron`): 30 napnál régebben törölt tételek; párosítatlan vagy visszavont névtelen fiókok 24 óra után; lejárt párosító kódok.
- Realtime: `lists`, `items` (a `postgres_changes` az RLS-t alkalmazza).

## Közös kód (`laszlobiri-com/lib/v1/`)

| fájl | szerep |
| --- | --- |
| `config.js` | projekt URL + publishable kulcs |
| `supabase.js` | generált csomag: `@supabase/supabase-js` 2.118.0 + `@supabase/ssr` 0.12.7 (`npm run build:lib`) |
| `client.js` | a közös kliens, `.laszlobiri.com` sütivel |
| `auth.js` | `getUser`, `getProfile`, `signIn`, `signOut`, `onAuthChange`, `safeNext`; a belépőoldalnak `startGoogleLogin`, `completeLogin` |
| `gate.js` | belépési kapu (`ready` → `{ user, offline }`) |
| `auth-badge.js` | `<lb-auth>`: név + Kilépés |
| `outbox.js` | kimenő sor (localStorage), sorrendben küld, hálózati hibánál megtartja, fülek között zárolva |
| `device.js` | gyerek mód: névtelen eszközfiók saját tárolóval (`lb-device-auth`), párosítás, PIN (PBKDF2), kilépés |

Az útvonal és az exportált nevek publikus szerződés; törő változás csak `lib/v2/` alatt. Bekötés: [`design-system/README.md`](../design-system/README.md).

## Az oldalak működése

### Bevásárlólista

- Háztartásonként egy közös lista. Minden módosítás azonnal helyben megjelenik és a kimenő sorba kerül; szinkron megnyitáskor, előtérbe kerüléskor, visszatérő hálózatnál, minden módosítás után, és ha a másik telefon változtat (Realtime). Szinkronkor a teljes élő lista jön le, rá a még el nem küldött műveletek.
- Ha két telefon offline ugyanazt veszi fel, a második a meglévőhöz csatlakozik („már rajta volt”), és az ő mennyisége érvényesül.
- Törlés: soft delete, így szinkronizálódik és visszavonható. A gyakran vett javaslatok közösek.
- A linkes küldés megszűnt; a szöveges megosztás megmaradt.

### Gyakorló

- Szülő: „Ki gyakorol?” → gyerek; szülői nézet: gyerekprofilok, eredmények (utolsó 5 kör), gyerek tabletek (párosítás, visszavonás, „Ez az eszköz legyen a gyerek tablet”), jelentett feladatok.
- A pont, a szint, a napi sorozat, a témánkénti legjobb és a jelvények az eredményekből számolódnak. Csak a befejezett kör és a megnyert minijáték mentődik.
- Gyerek mód: a tablet csak a hozzá rendelt gyerekeket látja; kilépés „Szülő” → PIN.
- Minijáték: 1000 pontonként jutalom; a gyerek választ akasztófa, szókereső és falbontó (2 × 6 tégla, 3 élet, a téma színeivel) közül. Egy jutalom egy játék; győzelem +10 pont.
- Színtéma: a gyerek maga választja a kezdőképernyőn („Színem”): palakék, rózsaszín (sötét) vagy égkék (világos). A választott téma a gyerek saját nézeteiben él, a „Ki gyakorol?” és a szülői nézet palakék.
- Hibás feladat: a kérdésnél „⚑” → okkód; a szülői nézetben „Javítva” / „Elvetés” és „Szövegként másolás” a javításhoz (a gyerek neve nélkül).

## Döntések

| kérdés | döntés |
| --- | --- |
| munkamenet az aloldalak között | közös süti (`.laszlobiri.com`) |
| használat belépés nélkül | nincs; böngészős kapu minden oldalon, a `/belepes/` és az `/adatvedelem/` kivételével. Szerveroldali védelem (más tárhely) elvetve. |
| felhasználók | két szülő, egy `parent` szerep; további szerep egy migrációval vehető fel |
| gyerekprofilok | kettő; a becenevek csak az adatbázisban, a repókban nem |
| gyerekek saját eszköze | gyerek mód: névtelen, párosított eszközfiók, PIN-nel lehet kilépni |
| listák | egy közös lista háztartásonként; közös gyorsjavaslatok |
| félbehagyott kör | nem számít |
| minijáték | 1000 pontonként, választható (akasztófa, szókereső, falbontó), egy jutalom egy játék |
| régi helyi adatok (lista, pontok) | az új verzió első indításkor törli (`bevasarlo-lista.v1`, `gyakorlo.v1`), nem kerülnek fel |
| színtéma | gyerekenként, a gyerek választja; a jel színei nem változnak |
| hibás feladat | „⚑” jelentés okkóddal, szabad szöveg nélkül; a javítás a szülőn keresztül, a másolt szöveg alapján |
| tananyag bővítése | tankönyvfotók alapján, ebben a munkamenet-formában (nem külön feltöltő oldal); saját feladatok, a tankönyv szövege nem kerül a nyilvános repóba |
| egyszerűsítések a tervhez képest | IndexedDB helyett localStorage; delta-lekérés helyett teljes élő lista; allowlist `lower()`-rel, nem `citext`-tel |
| csomag | ingyenes Supabase + helyi, titkosított mentés (még nincs kész) |

## Munkamód

- Commit **szerzője**: Laszlo Biri `<lbiri84@users.noreply.github.com>`; **committere**: Claude `<noreply@anthropic.com>`. A környezet a commitokat a Claude kulcsával SSH-val aláírja, és a GitHub ezt csak `noreply@anthropic.com` committerrel fogadja el („Verified”). Valódi e-mail cím nem kerül commitba. (2026-11-14 előtti commitoknál a committer is a noreply cím volt, ezért azok aláíratlannak látszanak; nem írjuk át őket.)
- Munkaág: `claude/funny-turing-bphs2l` minden repóban. Élesítés: helyi merge commit a `main`-re, ugyanezzel a szerző–committer párossal (nem a GitHub-on készült merge, mert az a fiók elsődleges címét írhatja be).
- Sorrend: a `laszlobiri-com` élesítése (a `supabase-migrate` munkafolyamat a `main`-re került új migrációt magától lefuttatja; az Actions naplójában ellenőrizni), `npm run check:rls`, végül az aloldal. Kézi SQL nem kell. A munkafolyamat titkai: `SUPABASE_ACCESS_TOKEN` (szűkített token: csak ez a projekt, olvasási jog) és `SUPABASE_DB_PASSWORD`; lásd `supabase/README.md`.
- Minden változás előtt: `npm run test:db`, `npm run test:smoke`; élesítés után `npm run check:rls`.

## Tesztek (`laszlobiri-com`)

| parancs | mit ellenőriz |
| --- | --- |
| `npm run test:db` | pgTAP: allowlist és profil (001), közös lista (002), gyakorló és gyerek mód (003), színtéma (004), jelentések (005), falbontó-eredmény (006). Helyi Postgresen, Supabase-stubbal. |
| `npm run test:smoke` | böngészős próbák ál-Supabase-zel: belépés és kapu (`login-smoke`), kéttelefonos listaszinkron (`list-sync-smoke`), gyakorló szülővel és tablettel (`practice-smoke`). A bevasarlo-lista és a gyakorlas repó a laszlobiri-com mellett legyen. |
| `npm run check:rls` | az éles projekt a nyilvános kulccsal: bejelentkezés nélkül semmi nem olvasható és írható. Proxy mögött `NODE_USE_ENV_PROXY=1`. |

## Hátralévő munka

1. **Mentés** (4. fázis): `scripts/backup.sh` a saját gépen: `supabase db dump` (séma; a `public` és `private` adat; az `auth.users` és `auth.identities`), `age` jelszavas titkosítás, `~/laszlobiri-backup/`, a legutóbbi 12 megtartása, ellenőrzés a végén; a Session pooler címe a `SUPABASE_DB_URL`-ből, jelszó soha fájlba. Havonta és minden migráció előtt; másolat egy második helyre.
2. **Visszaállítás próba**: `scripts/restore-local.sh` egy helyi `supabase start` példányba, negyedévente.
3. **Export az oldalakon**: „Adataim letöltése” JSON-ban (lista, előzmények; szülőnek a gyerekek eredményei).
4. **Szüneteltetés figyelése**: az ingyenes projekt egy hét tétlenség után szünetel. Ha előfordul, egy heti kérés a publikus kulccsal életben tarthatja (előbb ellenőrizni, hogy aktivitásnak számít-e).
5. **Dashboardon ellenőrizendő** (kívülről nem látszik): Database → Publications → `supabase_realtime` tartalmazza a `lists` és `items` táblát; Database → Cron Jobs alatt ott a `laszlobiri-items-purge` és a `laszlobiri-devices-cleanup`. Ha valamelyik hiányzik, a `pg_cron` nem volt bekapcsolva a migrációkor: bekapcsolás után a megfelelő migráció végét újra kell futtatni.
6. **Kézi próbák**, amik még nincsenek meg: bevásárlólista két telefonon (szinkron, offline, azonos tétel, gyorsjavaslatok); gyakorló (két profil, tablet párosítása telepített appban, offline kör a tableten, színválasztás a tableten).
7. **Opcionális**: PIN a szülői nézethez szülői belépés mellett is (ha a gyerek a szülő telefonján játszik); a gyakorló feladatai külön adatfájlokba az első nagyobb tananyag-bővítésnél.
