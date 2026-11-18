-- Az oldal-pipa az adatot is védi: a bevásárlólistához a 'bevasarlas', a gyakorló szülői
-- adataihoz a 'gyakorlas' kell, a háztartás-tagság mellett. A gyerek tablet nem változik.
--
-- Szereplők (kitalált adatok), mind az A háztartás tagjai:
--   MIND: Lista és Gyakorló
--   LI:   csak Lista
--   GY:   csak Gyakorló
--   SEM:  háztartás-tag, de egyik családi oldal sincs (pl. csak Interfood)
--   T:    a gyerekhez párosított tablet

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(26);

insert into public.households (id, name) values ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás');
insert into private.allowed_emails (email, household_id, apps) values
  ('mind@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000', '{bevasarlas,gyakorlas}'),
  ('li@example.invalid',   'aaaaaaaa-0000-0000-0000-000000000000', '{bevasarlas}'),
  ('gy@example.invalid',   'aaaaaaaa-0000-0000-0000-000000000000', '{gyakorlas}'),
  ('sem@example.invalid',  'aaaaaaaa-0000-0000-0000-000000000000', '{ebed}');
insert into auth.users (id, email) values
  ('11111111-1111-0000-0000-000000000000', 'mind@example.invalid'),
  ('22222222-2222-0000-0000-000000000000', 'li@example.invalid'),
  ('33333333-3333-0000-0000-000000000000', 'gy@example.invalid'),
  ('44444444-4444-0000-0000-000000000000', 'sem@example.invalid');
insert into auth.users (id, is_anonymous) values ('7a7a7a7a-0000-0000-0000-000000000000', true);

insert into public.pupils (id, household_id, nickname) values ('99999999-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000000', 'Mókus');
insert into public.devices (user_id, household_id, label) values ('7a7a7a7a-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000000', 'Tablet');
insert into public.device_pupils (device_user_id, pupil_id) values ('7a7a7a7a-0000-0000-0000-000000000000', '99999999-0000-0000-0000-000000000000');
insert into public.items (list_id, name, name_key)
select id, 'Tej', 'tej' from public.lists where household_id = 'aaaaaaaa-0000-0000-0000-000000000000';

\set MIND '''11111111-1111-0000-0000-000000000000'''
\set LI   '''22222222-2222-0000-0000-000000000000'''
\set GY   '''33333333-3333-0000-0000-000000000000'''
\set SEM  '''44444444-4444-0000-0000-000000000000'''
\set T    '''7a7a7a7a-0000-0000-0000-000000000000'''

-- ---------------------------------------------------------------- bevásárlólista
select is(pg_temp.count_as(:MIND, 'select * from public.items'), 1, 'lista: Lista+Gyakorló látja a tételeket');
select is(pg_temp.count_as(:LI,   'select * from public.items'), 1, 'lista: csak Lista látja a tételeket');
select is(pg_temp.count_as(:GY,   'select * from public.items'), 0, 'lista: csak Gyakorló nem látja a tételeket');
select is(pg_temp.count_as(:SEM,  'select * from public.items'), 0, 'lista: családi oldal nélkül nem látja a tételeket');
select is(pg_temp.count_as(:GY,   'select * from public.lists'), 0, 'lista: csak Gyakorló a listát sem látja');
select is(pg_temp.err_as(:LI, $$insert into public.items (list_id, name, name_key) values ((select id from public.lists limit 1), 'Kenyér', 'kenyer')$$),
  'ok', 'lista: csak Lista írhat');
select is(pg_temp.err_as(:GY, $$insert into public.items (list_id, name, name_key) values ((select l.id from public.lists l where l.household_id = 'aaaaaaaa-0000-0000-0000-000000000000'), 'Vaj', 'vaj')$$),
  '42501', 'lista: csak Gyakorló nem írhat');
select is(pg_temp.err_as(:LI, $$select public.bump_history('aaaaaaaa-0000-0000-0000-000000000000', 'tej', 'Tej', 'tej')$$), 'ok', 'lista: csak Lista: gyorsjavaslat számlálása');
select is(pg_temp.err_as(:GY, $$select public.bump_history('aaaaaaaa-0000-0000-0000-000000000000', 'tej', 'Tej', 'tej')$$), '42501', 'lista: csak Gyakorló: gyorsjavaslat tilos');
select is(pg_temp.count_as(:GY, 'select * from public.item_history'), 0, 'lista: csak Gyakorló nem látja a javaslatokat');

-- ---------------------------------------------------------------- gyakorló
select is(pg_temp.count_as(:MIND, 'select * from public.pupils'), 1, 'gyakorló: Lista+Gyakorló látja a gyereket');
select is(pg_temp.count_as(:GY,   'select * from public.pupils'), 1, 'gyakorló: csak Gyakorló látja a gyereket');
select is(pg_temp.count_as(:LI,   'select * from public.pupils'), 0, 'gyakorló: csak Lista nem látja a gyereket');
select is(pg_temp.count_as(:SEM,  'select * from public.pupils'), 0, 'gyakorló: családi oldal nélkül nem látja a gyereket');
select is(pg_temp.count_as(:LI,   'select * from public.devices'), 0, 'gyakorló: csak Lista nem látja a tableteket');
select is(pg_temp.err_as(:LI, $$insert into public.pupils (household_id, nickname) values ('aaaaaaaa-0000-0000-0000-000000000000', 'Süni')$$),
  '42501', 'gyakorló: csak Lista nem vehet fel gyereket');
select is(pg_temp.err_as(:GY, $$insert into public.results (pupil_id, kind, topic, score) values ('99999999-0000-0000-0000-000000000000', 'round', 'm101', 8)$$),
  'ok', 'gyakorló: csak Gyakorló eredményt menthet');
select is(pg_temp.err_as(:LI, $$insert into public.results (pupil_id, kind, topic, score) values ('99999999-0000-0000-0000-000000000000', 'round', 'm101', 8)$$),
  '42501', 'gyakorló: csak Lista nem menthet eredményt');
select is(pg_temp.count_as(:LI, 'select * from public.results'), 0, 'gyakorló: csak Lista nem látja az eredményeket');
select is(pg_temp.err_as(:LI, $$select public.create_pairing(array['99999999-0000-0000-0000-000000000000']::uuid[], 'x')$$),
  '42501', 'gyakorló: csak Lista nem párosíthat tabletet');
select is(pg_temp.count_as(:LI, 'select * from public.chapter_access'), 0, 'gyakorló: csak Lista nem látja a fejezet-beállítást');

-- ---------------------------------------------------------------- tablet: változatlan
select is(pg_temp.count_as(:T, 'select * from public.pupils'), 1, 'tablet: látja a hozzá rendelt gyereket');
select is(pg_temp.err_as(:T, $$insert into public.results (pupil_id, kind, topic, score) values ('99999999-0000-0000-0000-000000000000', 'round', 'm101', 9)$$),
  'ok', 'tablet: eredményt menthet');
select is(pg_temp.count_as(:T, 'select * from public.items'), 0, 'tablet: a listát nem látja');

-- ---------------------------------------------------------------- az oldal elvétele azonnal hat
update private.allowed_emails set apps = '{bevasarlas}' where email = 'mind@example.invalid';
select is(pg_temp.count_as(:MIND, 'select * from public.pupils'), 0, 'a Gyakorló elvétele után a gyereket sem látja');
select is(pg_temp.count_as(:MIND, 'select * from public.items'), 2, 'a Lista megmaradt: a tételeket látja');

select * from finish();
rollback;
