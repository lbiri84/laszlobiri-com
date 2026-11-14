-- 1. fázis: allowlist, profil-trigger és az alaptáblák RLS-e.
-- Futtatás: scripts/test-db.sh (helyi Postgres), vagy `supabase test db`.
--
-- Szereplők (kitalált adatok):
--   A1, A2: az A háztartás két szülője
--   B:      a B háztartás szülője
--   C:      engedélyezett cím, háztartás nélkül

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(38);

-- ---------------------------------------------------------------- előkészítés
insert into public.households (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'B háztartás');

insert into private.allowed_emails (email, household_id, app_role) values
  ('a1@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000', 'admin'),
  ('a2@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000', 'user'),
  ('b@example.invalid',  'bbbbbbbb-0000-0000-0000-000000000000', 'user'),
  ('c@example.invalid',  null, 'user');

-- ---------------------------------------------------------------- hook
select is(
  private.hook_before_user_created('{"user": {"email": "a1@example.invalid", "is_anonymous": false}}'),
  '{}'::jsonb, 'hook: engedélyezett cím átmegy');
select is(
  private.hook_before_user_created('{"user": {"email": "a2@EXAMPLE.invalid"}}'),
  '{}'::jsonb, 'hook: a kis- és nagybetű nem számít');
select is(
  private.hook_before_user_created('{"user": {"email": "idegen@example.invalid"}}') -> 'error' ->> 'http_code',
  '403', 'hook: ismeretlen cím 403');
select is(
  private.hook_before_user_created('{"user": {"email": null, "is_anonymous": true}}'),
  '{}'::jsonb, 'hook: névtelen fiók (gyerek mód) átmegy');
select is(
  private.hook_before_user_created('{"user": {}}') -> 'error' ->> 'http_code',
  '403', 'hook: e-mail nélküli, nem névtelen fiók 403');

-- ---------------------------------------------------------------- trigger
select throws_ok(
  $$insert into auth.users (email) values ('idegen@example.invalid')$$,
  '42501', null, 'trigger: ismeretlen cím nem hozható létre');

insert into auth.users (id, email, raw_user_meta_data) values
  ('a1a1a1a1-0000-0000-0000-000000000000', 'a1@example.invalid', '{"full_name": "Első Szülő"}'),
  ('a2a2a2a2-0000-0000-0000-000000000000', 'A2@Example.invalid', '{"name": "Második Szülő"}'),
  ('b0b0b0b0-0000-0000-0000-000000000000', 'b@example.invalid',  '{}'),
  ('c0c0c0c0-0000-0000-0000-000000000000', 'c@example.invalid',  '{}');
insert into auth.users (id, email, is_anonymous) values
  ('d0d0d0d0-0000-0000-0000-000000000000', null, true);

select is((select display_name from public.profiles where id = 'a1a1a1a1-0000-0000-0000-000000000000'),
  'Első Szülő', 'trigger: név a full_name mezőből');
select is((select display_name from public.profiles where id = 'a2a2a2a2-0000-0000-0000-000000000000'),
  'Második Szülő', 'trigger: név a name mezőből');
select is((select display_name from public.profiles where id = 'b0b0b0b0-0000-0000-0000-000000000000'),
  'b', 'trigger: név híján az e-mail helyi része');
select is((select app_role from public.profiles where id = 'a1a1a1a1-0000-0000-0000-000000000000'),
  'admin', 'trigger: app_role az allowlistből');
select is((select count(*)::int from public.household_members where household_id = 'aaaaaaaa-0000-0000-0000-000000000000'),
  2, 'trigger: A1 és A2 az A háztartás tagja');
select is((select count(*)::int from public.household_members where user_id = 'c0c0c0c0-0000-0000-0000-000000000000'),
  0, 'trigger: háztartás nélküli címhez nincs tagság');
select is((select count(*)::int from public.profiles where id = 'd0d0d0d0-0000-0000-0000-000000000000'),
  0, 'trigger: névtelen fióknak nincs profilja');

-- ---------------------------------------------------------------- olvasás
select is(pg_temp.count_as('a1a1a1a1-0000-0000-0000-000000000000', 'select * from public.profiles'),
  2, 'A1 a saját és A2 profilját látja');
select is(pg_temp.count_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$select * from public.profiles where id = 'b0b0b0b0-0000-0000-0000-000000000000'$$),
  0, 'A1 nem látja B profilját');
select is(pg_temp.q_as('a1a1a1a1-0000-0000-0000-000000000000', 'select id from public.households'),
  '[{"id": "aaaaaaaa-0000-0000-0000-000000000000"}]'::jsonb, 'A1 csak az A háztartást látja');
select is(pg_temp.count_as('a1a1a1a1-0000-0000-0000-000000000000', 'select * from public.household_members'),
  2, 'A1 csak az A háztartás tagjait látja');
select is(pg_temp.count_as('b0b0b0b0-0000-0000-0000-000000000000',
  $$select * from public.households where id = 'aaaaaaaa-0000-0000-0000-000000000000'$$),
  0, 'B nem látja az A háztartást, ismert id-val sem');
select is(pg_temp.count_as('b0b0b0b0-0000-0000-0000-000000000000',
  $$select * from public.household_members where household_id = 'aaaaaaaa-0000-0000-0000-000000000000'$$),
  0, 'B nem látja az A háztartás tagjait');
select is(pg_temp.count_as('c0c0c0c0-0000-0000-0000-000000000000', 'select * from public.profiles'),
  1, 'C csak a saját profilját látja');
select is(pg_temp.count_as('c0c0c0c0-0000-0000-0000-000000000000', 'select * from public.households'),
  0, 'C nem lát háztartást');
select is(pg_temp.count_as('d0d0d0d0-0000-0000-0000-000000000000', 'select * from public.profiles'),
  0, 'a párosítatlan névtelen fiók nem lát profilt');

-- ---------------------------------------------------------------- írás
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.profiles set display_name = 'Új Név' where id = 'a1a1a1a1-0000-0000-0000-000000000000'$$),
  1, 'A1 átírhatja a saját nevét');
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.profiles set display_name = 'Feltört' where id = 'a2a2a2a2-0000-0000-0000-000000000000'$$),
  0, 'A1 nem írhatja át A2 nevét');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.profiles set app_role = 'admin' where id = 'a1a1a1a1-0000-0000-0000-000000000000'$$),
  '42501', 'senki nem írhatja a saját app_role-ját');
select is(pg_temp.err_as('c0c0c0c0-0000-0000-0000-000000000000',
  $$insert into public.household_members (household_id, user_id) values ('aaaaaaaa-0000-0000-0000-000000000000', 'c0c0c0c0-0000-0000-0000-000000000000')$$),
  '42501', 'C nem veheti fel magát az A háztartásba');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$delete from public.household_members where user_id = 'a2a2a2a2-0000-0000-0000-000000000000'$$),
  '42501', 'A1 nem törölheti A2 tagságát a kliensből');
select is(pg_temp.err_as('c0c0c0c0-0000-0000-0000-000000000000',
  $$insert into public.households (name) values ('Saját')$$),
  '42501', 'kliensből nem hozható létre háztartás');
select is(pg_temp.err_as('c0c0c0c0-0000-0000-0000-000000000000',
  $$insert into public.profiles (id, display_name) values ('c0c0c0c0-0000-0000-0000-000000000000', 'x')$$),
  '42501', 'kliensből nem hozható létre profil');
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.households set name = 'Család' where id = 'aaaaaaaa-0000-0000-0000-000000000000'$$),
  1, 'A1 átnevezheti a saját háztartását');
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.households set name = 'Feltört' where id = 'bbbbbbbb-0000-0000-0000-000000000000'$$),
  0, 'A1 nem nevezheti át a B háztartást');
select is((select name from public.households where id = 'bbbbbbbb-0000-0000-0000-000000000000'),
  'B háztartás', 'a B háztartás neve változatlan');

-- ---------------------------------------------------------------- anon és private
select is(pg_temp.err_as(null, 'select * from public.profiles'),
  '42501', 'anon: profiles nem olvasható');
select is(pg_temp.err_as(null, 'select * from public.households'),
  '42501', 'anon: households nem olvasható');
select is(pg_temp.err_as(null, 'select * from public.household_members'),
  '42501', 'anon: household_members nem olvasható');
select is(pg_temp.err_as(null, 'select * from private.allowed_emails'),
  '42501', 'anon: az allowlist nem olvasható');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000', 'select * from private.allowed_emails'),
  '42501', 'bejelentkezve sem olvasható az allowlist');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$select private.hook_before_user_created('{}'::jsonb)$$),
  '42501', 'a hook függvény kliensből nem hívható');

select * from finish();
rollback;
