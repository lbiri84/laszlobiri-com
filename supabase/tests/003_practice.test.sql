-- 3. fázis: gyerekprofilok, eredmények, jelvények, gyerek mód (eszközfiók, párosítás).
-- Szereplők (kitalált adatok): A1 szülő az A háztartásban, B szülő a B-ben,
-- D1, D2, D3 névtelen fiókok (gyerek tabletek).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(50);

-- ---------------------------------------------------------------- előkészítés
insert into public.households (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'B háztartás');
insert into private.allowed_emails (email, household_id) values
  ('a1@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000'),
  ('b@example.invalid',  'bbbbbbbb-0000-0000-0000-000000000000');
-- A családtagok a két családi oldalt is megkapják (lásd 008: az oldal-pipa az adatot is védi).
update private.allowed_emails set apps = '{ebed,bevasarlas,gyakorlas}' where household_id is not null;
insert into auth.users (id, email) values
  ('a1a1a1a1-0000-0000-0000-000000000000', 'a1@example.invalid'),
  ('b0b0b0b0-0000-0000-0000-000000000000', 'b@example.invalid');
insert into auth.users (id, is_anonymous) values
  ('d1d1d1d1-0000-0000-0000-000000000000', true),
  ('d2d2d2d2-0000-0000-0000-000000000000', true),
  ('d3d3d3d3-0000-0000-0000-000000000000', true);

\set A1 '''a1a1a1a1-0000-0000-0000-000000000000'''
\set B  '''b0b0b0b0-0000-0000-0000-000000000000'''
\set D1 '''d1d1d1d1-0000-0000-0000-000000000000'''
\set D2 '''d2d2d2d2-0000-0000-0000-000000000000'''
\set D3 '''d3d3d3d3-0000-0000-0000-000000000000'''

-- ---------------------------------------------------------------- gyerekprofilok
select is(pg_temp.err_as(:A1, $$insert into public.pupils (id, household_id, nickname, avatar) values ('11111111-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000000', 'Mókus', 'fox')$$),
  'ok', 'A1 létrehoz egy gyerekprofilt');
select is(pg_temp.err_as(:A1, $$insert into public.pupils (id, household_id, nickname, avatar) values ('11111111-0000-0000-0000-00000000000b', 'aaaaaaaa-0000-0000-0000-000000000000', 'Süni', 'owl')$$),
  'ok', 'A1 létrehoz egy második gyerekprofilt');
select is(pg_temp.err_as(:A1, $$insert into public.pupils (household_id, nickname) values ('aaaaaaaa-0000-0000-0000-000000000000', ' mókus ')$$),
  '23505', 'ugyanaz a becenév kétszer nem lehet (kis- és nagybetű, szóköz nem számít)');
select is(pg_temp.err_as(:A1, $$insert into public.pupils (household_id, nickname, avatar) values ('aaaaaaaa-0000-0000-0000-000000000000', 'Harmadik', 'dragon')$$),
  '23514', 'ismeretlen ikon nem írható');
select is(pg_temp.err_as(:A1, format($$insert into public.pupils (household_id, nickname) values ('aaaaaaaa-0000-0000-0000-000000000000', %L)$$, repeat('x', 21))),
  '23514', '20 karakternél hosszabb becenév nem írható');
select is(pg_temp.err_as(:B, $$insert into public.pupils (household_id, nickname) values ('aaaaaaaa-0000-0000-0000-000000000000', 'Idegen')$$),
  '42501', 'B nem hozhat létre profilt A háztartásában');
select is(pg_temp.count_as(:B, 'select * from public.pupils'), 0, 'B nem látja A gyerekeit');
select is(pg_temp.count_as(:A1, 'select * from public.pupils'), 2, 'A1 látja a két gyereket');

-- ---------------------------------------------------------------- eredmények
select is(pg_temp.err_as(:A1, $$insert into public.results (id, pupil_id, kind, topic, score, best_streak, answered, correct, points) values ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'round', 'szorosz', 10, 10, 10, 10, 150)$$),
  'ok', 'A1 eredményt ment a gyereknek');
select is((select recorded_by from public.results where id = '22222222-0000-0000-0000-000000000001'),
  'a1a1a1a1-0000-0000-0000-000000000000'::uuid, 'a recorded_by a szerverről jön');
select is(pg_temp.err_as(:A1, $$insert into public.results (id, pupil_id, kind, topic, created_at) values ('22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000a', 'round', 'jly', now() + interval '1 day')$$),
  'ok', 'jövőbeli időponttal is menthető…');
select ok((select created_at <= now() from public.results where id = '22222222-0000-0000-0000-000000000002'),
  '…de az időpont a mostra korlátozódik');
select is(pg_temp.err_as(:A1, $$insert into public.results (pupil_id, kind) values ('11111111-0000-0000-0000-00000000000a', 'round')$$),
  '23514', 'kör téma nélkül nem menthető');
select is(pg_temp.err_as(:A1, $$insert into public.results (pupil_id, kind, answered, correct) values ('11111111-0000-0000-0000-00000000000a', 'hangman', 3, 5)$$),
  '23514', 'több jó válasz, mint válasz: nem menthető');
select is(pg_temp.err_as(:A1, $$insert into public.results (pupil_id, kind, topic) values ('11111111-0000-0000-0000-00000000000a', 'round', 'Szabad szöveg!')$$),
  '23514', 'a téma csak kód lehet, szabad szöveg nem');
select is(pg_temp.err_as(:A1, $$update public.results set score = 0 where id = '22222222-0000-0000-0000-000000000001'$$),
  '42501', 'eredmény nem írható át');
select is(pg_temp.err_as(:B, $$insert into public.results (pupil_id, kind, topic) values ('11111111-0000-0000-0000-00000000000a', 'round', 'jly')$$),
  '42501', 'B nem írhat eredményt A gyerekének');
select is(pg_temp.count_as(:B, 'select * from public.results'), 0, 'B nem látja A eredményeit');

-- ---------------------------------------------------------------- párosítás
select is(pg_temp.err_as(:B, $$select public.create_pairing(array['11111111-0000-0000-0000-00000000000a']::uuid[], 'tablet')$$),
  '42501', 'B nem kérhet kódot A gyerekéhez');
select is(pg_temp.err_as(:A1, $$select public.create_pairing(array['11111111-0000-0000-0000-00000000000a', 'ffffffff-0000-0000-0000-000000000000']::uuid[], 'tablet')$$),
  '42501', 'nem létező gyerekre sem kérhető kód');

create temp table codes (n int, code text);
grant select on codes to authenticated;
insert into codes select 1, pg_temp.q_as(:A1, $$select public.create_pairing(array['11111111-0000-0000-0000-00000000000a']::uuid[], 'Tablet') as c$$) -> 0 ->> 'c';
select matches((select code from codes where n = 1), '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$', 'a kód formája XXXX-XXXX');

select is(pg_temp.err_as(:A1, format('select public.claim_pairing(%L)', (select code from codes where n = 1))),
  '42501', 'szülői fiókkal nem váltható be (csak névtelen eszközfiókkal)');
select is(pg_temp.q_as(:D1, $$select public.claim_pairing('AAAA-AAAA') as r$$) -> 0 ->> 'r', 'invalid', 'hibás kód: elutasítva');
select is((select failures from private.pairing_attempts where user_id = :D1), 1, 'a hibás próbálkozás számlálódik');
select is(pg_temp.q_as(:D1, format('select public.claim_pairing(%L) as r', lower(replace((select code from codes where n = 1), '-', ' ')))) -> 0 ->> 'r',
  'ok', 'D1 beváltja a kódot (kisbetűvel, szóközzel is)');
select is((select count(*)::int from public.device_pupils where device_user_id = :D1), 1, 'D1-hez egy gyerek tartozik');
select is(pg_temp.q_as(:D2, format('select public.claim_pairing(%L) as r', (select code from codes where n = 1))) -> 0 ->> 'r',
  'invalid', 'a kód egyszer használható');
select is(pg_temp.err_as(:D1, format('select public.claim_pairing(%L)', (select code from codes where n = 1))),
  '22023', 'párosított eszköz nem párosítható újra');

-- ---------------------------------------------------------------- az eszköz jogai
select is(pg_temp.q_as(:D1, 'select nickname from public.pupils'), '[{"nickname": "Mókus"}]'::jsonb, 'D1 csak a hozzá rendelt gyereket látja');
select is(pg_temp.err_as(:D1, $$insert into public.results (id, pupil_id, kind, topic, score, answered, correct, points) values ('22222222-0000-0000-0000-000000000003', '11111111-0000-0000-0000-00000000000a', 'round', 'abc', 7, 10, 7, 70)$$),
  'ok', 'D1 eredményt ment a hozzá rendelt gyereknek');
select is(pg_temp.err_as(:D1, $$insert into public.results (pupil_id, kind, topic) values ('11111111-0000-0000-0000-00000000000b', 'round', 'abc')$$),
  '42501', 'D1 nem ment a másik gyereknek');
select is(pg_temp.count_as(:D1, 'select * from public.results'), 3, 'D1 a hozzá rendelt gyerek eredményeit látja');
select is(pg_temp.n_as(:D1, $$delete from public.results$$), 0, 'D1 nem törölhet eredményt');
select is(pg_temp.err_as(:D1, $$insert into public.pupil_badges (pupil_id, badge_id) values ('11111111-0000-0000-0000-00000000000a', 'elso')$$),
  'ok', 'D1 jelvényt ment a hozzá rendelt gyereknek');
select is(pg_temp.err_as(:D1, $$insert into public.pupil_badges (pupil_id, badge_id) values ('11111111-0000-0000-0000-00000000000b', 'elso')$$),
  '42501', 'D1 nem ment jelvényt a másik gyereknek');
select is(pg_temp.count_as(:D1, 'select * from public.lists'), 0, 'D1 nem lát bevásárlólistát');
select is(pg_temp.count_as(:D1, 'select * from public.items'), 0, 'D1 nem lát bevásárlólista-tételt');
select is(pg_temp.count_as(:D1, 'select * from public.households'), 0, 'D1 nem látja a háztartást');
select is(pg_temp.count_as(:D1, 'select * from public.profiles'), 0, 'D1 nem látja a szülők profilját');
select is(pg_temp.err_as(:D1, $$select public.create_pairing(array['11111111-0000-0000-0000-00000000000a']::uuid[], 'x')$$),
  '42501', 'D1 nem kérhet új kódot');
select is(pg_temp.n_as(:D1, format($$update public.devices set last_seen_at = now(), label = 'Feltört' where user_id = %L$$, :D1)), 1, 'D1 frissíti a last_seen_at-et…');
select is((select label from public.devices where user_id = :D1), 'Tablet', '…de a címkét nem írhatja át');
select is(pg_temp.count_as(:D2, 'select * from public.pupils'), 0, 'párosítatlan névtelen fiók semmit nem lát');
select is(pg_temp.count_as(:B, 'select * from public.devices'), 0, 'B nem látja A eszközeit');

-- ---------------------------------------------------------------- lejárat, próbálkozások
insert into codes select 2, pg_temp.q_as(:A1, $$select public.create_pairing(array['11111111-0000-0000-0000-00000000000b']::uuid[], 'Másik') as c$$) -> 0 ->> 'c';
update private.device_pairings set expires_at = now() - interval '1 minute' where used_at is null;
select is(pg_temp.q_as(:D3, format('select public.claim_pairing(%L) as r', (select code from codes where n = 2))) -> 0 ->> 'r', 'invalid', 'lejárt kód: elutasítva');
insert into codes select 3, pg_temp.q_as(:A1, $$select public.create_pairing(array['11111111-0000-0000-0000-00000000000b']::uuid[], 'Harmadik') as c$$) -> 0 ->> 'c';
update private.pairing_attempts set failures = 10 where user_id = :D3;
select is(pg_temp.err_as(:D3, format('select public.claim_pairing(%L)', (select code from codes where n = 3))), '42501', '10 hibás próbálkozás után jó kóddal sem');

-- ---------------------------------------------------------------- visszavonás, takarítás, törlés
select is(pg_temp.n_as(:A1, format('delete from public.devices where user_id = %L', :D1)), 1, 'A1 visszavonja D1-et');
select is(pg_temp.count_as(:D1, 'select * from public.pupils'), 0, 'visszavonás után D1 semmit nem lát');
update auth.users set created_at = now() - interval '2 days' where id in (:D1, :D2);
select private.cleanup_devices();
select is((select count(*)::int from auth.users where id in (:D1, :D2)), 0, 'takarítás: a visszavont és a párosítatlan névtelen fiók törlődik');

select is(pg_temp.err_as(null, 'select * from public.pupils'), '42501', 'anon: pupils nem olvasható');

select * from finish();
rollback;
