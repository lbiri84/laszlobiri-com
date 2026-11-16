# laszlobiri

Laszlo személyes oldala és kis alkalmazásai (laszlobiri.com). A márka egy pontmátrix: az **L** és a **B** betű egyetlen, elforgatott rácsban, alatta a kisbetűs „laszlobiri” felirattal. Sötét palakék alapon fehéres, narancs és fekete.

## Tartalmi alapelvek

- A név mindig **laszlobiri**, kisbetűvel, egy szóban. Mondat elején sem írjuk nagybetűvel.
- Hangnem: személyes, rövid, tárgyilagos. Egy mondat, ami elmondja, mit csinál az oldal. Felkiáltójel, szlogen és marketingnyelv nélkül.
- Magyar a felület alapnyelve. A kód, a tokenek és a fájlnevek angolul vannak.
- Példák: „Heti ebéd” és „Bevásárlólista”, nem „Fedezd fel a heti ebédválasztót!”.

## Vizuális alapok

- **Alap**: palakék (`bg`), rajta fehéres szöveg (`fg`). Világos téma is van: fehéres alap, sötét szöveg.
- **Egyetlen kiemelő szín**: narancs. A B betűn, a „biri” feliraton, linkeken és főgombokon. Oldalanként egy-két helyen, nem tapétának.
- **Fekete** csak mélységnek: sötét blokkok, és a jel L betűje világos alapon.
- **Forma**: a jel szögletes, háromszög-lapokra bontott betűi (low-poly) és lekerekített téglalapok (`radius-md`, `radius-lg`). Nincs színátmenet, nincs árnyék, nincs keret-csík a kártyák szélén.
- **Betűtípus**: Space Grotesk (Google Fonts), 400–700. A felirat 600-as, szoros betűközzel (-0,03em).
- **Sűrűség**: nagyvonalú. Oldalmargó `space-16`, szekciók között `space-12`.

## A jel

A jel egy monogram (2026-11-16 óta): nagy **L** és kis **b** egymás mellett, kis réssel, szögletes (low-poly) formában. A betűk háromszög-lapokból állnak; a lapok átlátszósága (`fill-opacity` 1 és 0,66 között) adja a hajtott papír hatását. `viewBox="4 6 86 88"` (100-as keretben).

| elem | alak | szín |
| --- | --- | --- |
| L | szár (x 4–18) és talp (x 4–34, y 78–92), négy háromszög-lap | `mark-l` |
| b | ferdén vágott szár (x 40–54, teteje 14-ről 6-ra emelkedik) és hatszögletű has hat háromszög-lappal | `mark-b` (narancs) |

A régi jelek tokenjei (`mark-ring`, `mark-filler`) megmaradnak, az új jel nem használja őket.

### A jel, palakék alapon

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="4 6 86 88" width="172" height="176"><rect x="4" y="6" width="86" height="88" fill="#293c4b"/><polygon fill="#eaecf0" points="4,8 18,8 18,92"/><polygon fill="#eaecf0" points="4,8 18,92 4,92" fill-opacity="0.8"/><polygon fill="#eaecf0" points="4,78 34,78 34,92" fill-opacity="0.9"/><polygon fill="#eaecf0" points="4,78 34,92 4,92" fill-opacity="0.72"/><polygon fill="#ee8643" points="40,14 54,6 54,92"/><polygon fill="#ee8643" points="40,14 54,92 40,92" fill-opacity="0.84"/><polygon fill="#ee8643" points="70,70 54,46 76,46"/><polygon fill="#ee8643" points="70,70 76,46 90,62" fill-opacity="0.74"/><polygon fill="#ee8643" points="70,70 90,62 86,86" fill-opacity="0.9"/><polygon fill="#ee8643" points="70,70 86,86 72,94" fill-opacity="0.66"/><polygon fill="#ee8643" points="70,70 72,94 54,92" fill-opacity="0.82"/><polygon fill="#ee8643" points="70,70 54,92 54,46" fill-opacity="0.95"/></svg>
```

Világos alapon a világos téma tokenjeivel (`mark-l` fekete; a b itt is narancs). Inline használatnál a lapok osztályt kapnak (`l`, `b`), a színt a tokenek adják:

```css
.mk .l{fill:var(--mark-l)}.mk .b{fill:var(--mark-b)}
```

### Lockup és szabályok

- **Lockup**: a jel fölül vagy balra; mellette vagy alatta a „laszlobiri” felirat. A „laszlo” `fg`, a „biri” narancs (`accent`).
- **Védőtér**: minden oldalon legalább a jel szélességének 15%-a.
- **Legkisebb méret**: a jel 20 px széles.
- Ne forgasd el, ne nyújtsd, ne told össze a két betűt, és ne cserélj színt: az L `mark-l`, a b narancs.

## Szín

| token | érték | mire |
| --- | --- | --- |
| `brand-slate` | `#293c4b` | alap |
| `brand-orange` | `#ee8643` | kiemelés |
| `brand-mist` | `#eaecf0` | szöveg és L betű sötét alapon |
| `brand-black` | `#000000` | kitöltő pöttyök, sötét blokkok |

Kontraszt: a fehéres a palakéken 9,6:1. A narancs a palakéken csak 4,4:1, ezért kis szövegnek és linknek az `accent-text` kell (5,0:1), a `accent` 24 px fölötti szövegnek és grafikának jó. A narancs a fehéres alapon csak 2,2:1: ott a narancs csak a jelben és blokkokban szerepelhet, szövegnek az `accent-text` (4,7:1).

## Betűtípus

Space Grotesk, a Google Fontsból (`https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&display=swap`). Címek 600–700, szöveg 400. Tartalék: `system-ui, sans-serif`.

## Használat

Tokeneket a `tokens.css` adja (CSS változók, `--bg`, `--fg`, `--accent`…). A témát a `data-theme="slate"` vagy `data-theme="light"` választja. Új oldalnál az `bg` háttérre és az `fg` szövegre épülj, és a narancshoz az `accent-text`-et használd, ha szöveg.

### Új oldal vagy app bekötése (központi tokenek)

A `tokens.css` egyetlen példánya itt van, és közzé van téve: **`https://laszlobiri.com/design-system/tokens.css`**. Az aloldalak (Interfood, Bevásárlólista, Gyakorló és minden új) ezt töltik be, **nem tartanak helyi másolatot**:

```html
<link rel="preconnect" href="https://laszlobiri.com">
<link rel="stylesheet" href="https://laszlobiri.com/design-system/tokens.css">
```

Szabályok:

- **Ne másold** a `tokens.css`-t az aloldal repójába, és ne vedd fel a közzétételi (Actions) másoló lépésbe. Token módosítása csak itt, a `tokens.json`-ban történik, utána a `tokens.css` újragenerálása, és az aloldalak maguktól megkapják.
- **Az útvonal publikus szerződés**: a `design-system/tokens.css` nem nevezhető át és nem mozdítható el, és a változónevek (`--bg`, `--fg`, `--accent`…) nem törölhetők vagy nevezhetők át, mert az aloldalak ezektől függenek. Törő változtatásnál előbb új, verziózott útvonal (pl. `design-system/v2/tokens.css`) jöjjön létre, és az aloldalakat egyenként át kell állítani.
- **Ami helyben marad az aloldalon**: az `icon.svg` és az alkalmazás ikonjai (a manifest és az `apple-touch-icon` miatt), a téma kiválasztása (`data-theme`) és az oldal saját CSS-e. Egy aloldal saját témát is adhat a tokenek felülírásával a saját CSS-ében (pl. a gyakorló `data-theme="rose"`), a kontraszt-szabályok betartásával; a jel (`mark-*`) színei ilyenkor sem változnak.
- **PWA-nál** (service worker): a `tokens.css` ne kerüljön az előre mentett (`ASSETS`) listába, mert az install lépés CORS nélkül elbukhat. A hálózat-először kezelő az első betöltéskor lementi, így offline is elérhető.
- **Függés**: ha a `laszlobiri.com` nem érhető el, az aloldal stílus nélkül jelenik meg. A főoldal elérhetősége ezért mindhárom oldalra hat.
- **Ellenőrzés új oldalnál**: megnyitás után a böngésző hálózati paneljén a `tokens.css` kérésnek 200-assal kell visszajönnie.

### Belépés és közös adat (lib/v1)

A Supabase-kliens és a belépés közös kódja a design system mellett, a `lib/v1/` mappában van, és ugyanúgy a `laszlobiri.com` címről töltődik be, mint a `tokens.css`. Hogyan működik: `docs/backend-terv.md`; az adatbázis: `supabase/README.md`.

```html
<script type="module" src="https://laszlobiri.com/lib/v1/auth-badge.js"></script>
<lb-auth></lb-auth>
<script type="module">
  import { getUser, onAuthChange, signIn, signOut } from 'https://laszlobiri.com/lib/v1/auth.js';
  import { supabase, isConfigured } from 'https://laszlobiri.com/lib/v1/client.js';
</script>
```

Minden oldal **csak belépve** használható (kivétel a `/belepes/` és az `/adatvedelem/`). Ehhez a `<head>` elejére, minden más elé:

```html
<style id="lb-gate">html{visibility:hidden}</style>
<script>/* lb-gate */if(!/(?:^|;\s*)sb-[a-z0-9]+-auth-token(?:\.0)?=/.test(document.cookie))location.replace('https://laszlobiri.com/belepes/?next='+encodeURIComponent(location.href))</script>
<script type="module" src="https://laszlobiri.com/lib/v1/gate.js"></script>
```

A kapu böngészőben működik: a fájlok továbbra is nyilvánosan letölthetők, az adatot az adatbázis RLS-e védi. Offline is beenged, ha a telefonon van munkamenet. A gyakorló oldal saját változatot használ, ami a párosított gyerek tabletet és a `#parositas` oldalt is átengedi (lásd a gyakorlas repót).

Szabályok:

- **Az útvonal és az exportált nevek publikus szerződés**, mint a tokeneké. Törő változásnál `lib/v2/` jön létre, és az aloldalakat egyenként kell átállítani.
- **Ne másold** a `lib/v1`-et az aloldal repójába, és ne tölts be Supabase-t közvetlenül CDN-ről. A `lib/v1/supabase.js` generált, rögzített verziójú csomag (`npm run build:lib`), kézzel nem szerkesztjük.
- **Kulcs**: a `lib/v1/config.js`-ben csak a projekt URL és a nyilvános (anon / publishable) kulcs lehet. A service role / secret kulcs soha nem kerül kliensbe vagy repóba.
- **Belépés**: minden oldal a központi `https://laszlobiri.com/belepes/?next=…` oldalra küld (`signIn()`). A munkamenet `.laszlobiri.com` domainű sütiben él, így egy belépés mindenhol érvényes, és a kilépés is mindenhol kiléptet.
- **Ha a `config.js` üres** (pl. egy új, még be nem kötött Supabase-projektnél), az `isConfigured` hamis: az `<lb-auth>` nem jelenik meg, és a kapu nem ellenőriz.
- **Felhasználói szöveg** (másik felhasználó által beírt név, tétel) csak `textContent`-tel vagy `esc()`-pel kerülhet a DOM-ba.
- **Offline mentés**: `lib/v1/outbox.js` (kimenő sor localStorage-ban, sorrendben küld, hálózati hibánál megtartja). Lásd a bevásárlólista és a gyakorló oldal használatát.
- **Gyerek mód**: `lib/v1/device.js` (névtelen, párosított eszközfiók saját tárolóval, PIN). Csak a gyakorló oldal használja; ott a kapu a párosított tabletet is beengedi.
- **PWA-nál** a service worker a `*.supabase.co` és a `laszlobiri.com/belepes/` kéréseket nem kezeli (a fetch kezelő `respondWith` nélkül visszatér), és a `lib/v1/*` nem kerül az `ASSETS` listába, ugyanazért, amiért a `tokens.css` sem.

## Fájlok ebben a repóban

- `tokens.json`: a tokenek forrása. `tokens.css`: ebből generált CSS-változók (`data-theme="slate"` vagy `"light"`); az aloldalak ezt a fájlt töltik be a `laszlobiri.com` címről (lásd fent).
- `assets/logo/mark-on-slate.svg` és `mark-on-light.svg`: a jel, palakék és világos alapra.
- `components/Logo`, `components/Cover`: az élő előnézetek (a Claude design system oldalán nyílnak meg, a `tokens.css`-t várják).
