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
- **Fekete** csak mélységnek: sötét blokkok, és a jel világos alapon.
- **Forma**: a jel pöttyökkel összekötött útvonala (14-es rácson) és lekerekített téglalapok (`radius-md`, `radius-lg`). Nincs színátmenet, nincs árnyék, nincs keret-csík a kártyák szélén.
- **Betűtípus**: Space Grotesk (Google Fonts), 400–700. A felirat 600-as, szoros betűközzel (-0,03em).
- **Sűrűség**: nagyvonalú. Oldalmargó `space-16`, szekciók között `space-12`.

## A jel

A jel egy útvonal: hat pötty cikcakkban, folytonos vonallal összekötve, bal alul indul és jobb fent ér célba (2026-11-16 óta; a vázlat 90°-kal balra forgatva). 14 egység rácstáv, `viewBox="0 0 86 72"`. A pontok rácskoordinátái (oszlop, sor): (0, 4), (1, 3), (2, 4), (3, 2), (4, 4), (5, 0); a margó 8 egység.

| elem | alak | szín |
| --- | --- | --- |
| út | folytonos vonal, 2,8 vastag, lekerekített végekkel és sarkokkal; a cél gyűrűjének szélén ér véget | `mark-l` |
| kezdőpont (bal alul) | tömör pötty, r = 5 | `mark-b` (narancs) |
| közbülső pontok | 4 tömör pötty, r = 4; a harmadik (a középső csúcs) r = 6 | `mark-l` |
| cél (jobb fent) | üres gyűrű, r = 4, vonal 2,8 | `mark-ring` (narancs) |
| háló (csak nagy méretben) | háromszögháló a jel pontjaiból és a keret pontjaiból, vonal 0,7, 9% átlátszóság, lekerekített keretre vágva (`viewBox="-12 -12 110 96"`) | `mark-l` |

A `mark-filler` token megmarad (a régi jelé volt), az új jel nem használja.

### A jel, palakék alapon

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 86 72" width="172" height="144"><rect width="86" height="72" fill="#293c4b"/><polyline stroke="#eaecf0" fill="none" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round" points="8,64 22,50 36,64 50,36 64,64 77.03,11.88"/><circle fill="#ee8643" cx="8" cy="64" r="5"/><circle fill="#eaecf0" cx="22" cy="50" r="4"/><circle fill="#eaecf0" cx="36" cy="64" r="4"/><circle fill="#eaecf0" cx="50" cy="36" r="6"/><circle fill="#eaecf0" cx="64" cy="64" r="4"/><circle stroke="#ee8643" cx="78" cy="8" r="4" fill="none" stroke-width="2.8"/></svg>
```

Világos alapon a világos téma tokenjeivel (`mark-l` fekete; a kezdőpont és a cél itt is narancs). Inline használatnál a jel osztályokkal készül (`ln`, `st`, `dt`, `en`, `ms`), a színt a tokenek adják:

```css
.mk .ln{stroke:var(--mark-l)}.mk .dt{fill:var(--mark-l)}.mk .st{fill:var(--mark-b)}.mk .en{stroke:var(--mark-ring)}.mk .ms{stroke:var(--mark-l);stroke-opacity:.09}
```

### Háló

A háló a jel mögötti halvány háromszögháló, csak nagy méretben (a főoldal és a belépés logója, a kezdőképernyő-ikon): `assets/logo/mark-mesh-on-slate.svg`, `mark-mesh-on-light.svg`. 64 px alatt nincs háló, ott a sima jel kell (fejlécek, böngészőfül-ikon).

### Lockup és szabályok

- **Lockup**: a jel fölül vagy balra; mellette vagy alatta a „laszlobiri” felirat. A „laszlo” `fg`, a „biri” narancs (`accent`).
- **Védőtér**: minden oldalon legalább egy rácstáv (14 egység, a jel szélességének 16%-a).
- **Legkisebb méret**: a jel 24 px széles; hálóval 64 px.
- Ne forgasd el, ne nyújtsd, ne szaggasd a vonalat, és ne cserélj színt: a kezdőpont és a cél narancs, a többi `mark-l`.

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
- `assets/logo/mark-on-slate.svg` és `mark-on-light.svg`: a jel, palakék és világos alapra; `mark-mesh-on-slate.svg` és `mark-mesh-on-light.svg`: hálóval.
- `components/Logo`, `components/Cover`: az élő előnézetek (a Claude design system oldalán nyílnak meg, a `tokens.css`-t várják).
