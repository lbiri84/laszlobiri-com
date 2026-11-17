-- Oldalankénti hozzáférés és az admin függvények.
--
-- Szereplők (kitalált adatok):
--   ADM: admin, az A háztartás szülője
--   A2:  az A háztartás másik szülője (nem admin)
--   L:   lakótárs: csak az elszámoló, háztartás nélkül
--   T:   gyerek tablet (névtelen fiók)

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(33);

insert into public.households (id, name) values ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás');
insert into private.allowed_emails (email, household_id, app_role, apps) values
  ('adm@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000', 'admin', '{ebed,bevasarlas,gyakorlas}'),
  ('a2@example.invalid',  'aaaaaaaa-0000-0000-0000-000000000000', 'user',  '{bevasarlas,gyakorlas}'),
  ('l@example.invalid',   null, 'user', '{elszamolas}');
insert into auth.users (id, email, last_sign_in_at) values
  ('adadadad-0000-0000-0000-000000000000', 'adm@example.invalid', now()),
  ('a2a2a2a2-0000-0000-0000-000000000000', 'a2@example.invalid', null),
  ('1e1e1e1e-0000-0000-0000-000000000000', 'L@Example.invalid', null);
insert into auth.users (id, is_anonymous) values ('7a7a7a7a-0000-0000-0000-000000000000', true);

\set ADM '''adadadad-0000-0000-0000-000000000000'''
\set A2  '''a2a2a2a2-0000-0000-0000-000000000000'''
\set L   '''1e1e1e1e-0000-0000-0000-000000000000'''
\set T   '''7a7a7a7a-0000-0000-0000-000000000000'''

-- ---------------------------------------------------------------- my_access
select is(pg_temp.q_as(:ADM, 'select public.my_access() as a') -> 0 -> 'a',
  '{"apps": ["ebed", "bevasarlas", "gyakorlas"], "admin": true}'::jsonb, 'my_access: admin, minden családi oldal');
select is(pg_temp.q_as(:L, 'select public.my_access() as a') -> 0 -> 'a',
  '{"apps": ["elszamolas"], "admin": false}'::jsonb, 'my_access: lakótárs csak az elszámolót (nagybetűs cím is)');
select is(pg_temp.q_as(:T, 'select public.my_access() as a') -> 0 -> 'a',
  '{"apps": [], "admin": false}'::jsonb, 'my_access: tablet: üres');
select is(pg_temp.err_as(null, 'select public.my_access()'), '42501', 'my_access: anon nem hívhatja');

-- ---------------------------------------------------------------- a lakótárs nem lát családi adatot
select is(pg_temp.count_as(:L, 'select * from public.households'), 0, 'lakótárs: háztartást nem lát');
select is(pg_temp.count_as(:L, 'select * from public.household_members'), 0, 'lakótárs: tagokat nem lát');
select is(pg_temp.count_as(:L, 'select * from public.profiles'), 1, 'lakótárs: csak a saját profilját látja');
select is(pg_temp.count_as(:L, 'select * from public.lists'), 0, 'lakótárs: bevásárlólistát nem lát');
select is(pg_temp.count_as(:L, 'select * from public.pupils'), 0, 'lakótárs: gyerekprofilt nem lát');

-- ---------------------------------------------------------------- admin lista
select is(pg_temp.err_as(:A2, 'select * from public.admin_access_list()'), '42501', 'lista: nem admin nem kérheti le');
select is(pg_temp.err_as(:L,  'select * from public.admin_access_list()'), '42501', 'lista: lakótárs nem kérheti le');
select is(pg_temp.err_as(:T,  'select * from public.admin_access_list()'), '42501', 'lista: tablet nem kérheti le');
select is(pg_temp.count_as(:ADM, 'select * from public.admin_access_list()'), 3, 'lista: admin minden címet lát');
select is(pg_temp.q_as(:ADM, $$select in_household, has_account, display_name from public.admin_access_list() where email = 'l@example.invalid'$$),
  '[{"in_household": false, "has_account": true, "display_name": "L"}]'::jsonb, 'lista: lakótárs: van fiókja, nincs a háztartásban');
select is(pg_temp.q_as(:ADM, $$select (last_sign_in_at is not null) as x from public.admin_access_list() where email = 'adm@example.invalid'$$),
  '[{"x": true}]'::jsonb, 'lista: utolsó belépés');

-- ---------------------------------------------------------------- admin felvétel / módosítás
select is(pg_temp.err_as(:A2, $$select public.admin_access_set('uj@example.invalid', '{ebed}', false)$$), '42501', 'felvétel: nem admin nem vehet fel');
select is(pg_temp.err_as(:ADM, $$select public.admin_access_set(' Uj@Example.INVALID ', '{elszamolas,elszamolas}', false, 'Lakás 3')$$), 'ok', 'felvétel: admin felvesz egy lakótársat');
select is((select row(apps, household_id, note, app_role)::text from private.allowed_emails where email = 'uj@example.invalid'),
  row('{elszamolas}'::text[], null::uuid, 'Lakás 3', 'user')::text, 'felvétel: kisbetűs cím, egyedi oldallista, háztartás nélkül, user szerep');
select is(pg_temp.err_as(:ADM, $$select public.admin_access_set('rossz', '{ebed}', false)$$), '22023', 'felvétel: érvénytelen cím');
select is(pg_temp.err_as(:ADM, $$select public.admin_access_set('x@example.invalid', '{admin}', false)$$), '22023', 'felvétel: ismeretlen oldal');
select is(pg_temp.err_as(:ADM, $$select public.admin_access_set('x@example.invalid', '{}', false, repeat('a', 81))$$), '22023', 'felvétel: túl hosszú megjegyzés');

-- Új cím háztartással: az első belépéskor a trigger teszi a háztartásba.
select is(pg_temp.err_as(:ADM, $$select public.admin_access_set('csalad@example.invalid', '{bevasarlas}', true)$$), 'ok', 'felvétel: családtag a háztartásba');
insert into auth.users (id, email) values ('cacacaca-0000-0000-0000-000000000000', 'csalad@example.invalid');
select is((select count(*)::int from public.household_members where user_id = 'cacacaca-0000-0000-0000-000000000000'), 1, 'felvétel: belépéskor háztartás-tag lett');

-- Meglévő fiók: a lakótárs háztartásba tétele és kivétele azonnal hat.
select is(pg_temp.err_as(:ADM, $$select public.admin_access_set('l@example.invalid', '{elszamolas}', true)$$), 'ok', 'módosítás: lakótárs a háztartásba (próba)');
select is((select count(*)::int from public.household_members where user_id = '1e1e1e1e-0000-0000-0000-000000000000'), 1, 'módosítás: tag lett');
select is(pg_temp.err_as(:ADM, $$select public.admin_access_set('l@example.invalid', '{elszamolas}', false)$$), 'ok', 'módosítás: kivétel a háztartásból');
select is((select count(*)::int from public.household_members where user_id = '1e1e1e1e-0000-0000-0000-000000000000'), 0, 'módosítás: már nem tag');
select is(pg_temp.err_as(:ADM, $$select public.admin_access_set('adm@example.invalid', '{ebed}', false)$$), '22023', 'módosítás: magát nem veheti ki a háztartásból');

-- ---------------------------------------------------------------- visszavonás
select is(pg_temp.err_as(:A2, $$select public.admin_access_remove('l@example.invalid')$$), '42501', 'visszavonás: nem admin nem vonhat vissza');
select is(pg_temp.err_as(:ADM, $$select public.admin_access_remove('adm@example.invalid')$$), '22023', 'visszavonás: magát nem vonhatja vissza');
select is(pg_temp.err_as(:ADM, $$select public.admin_access_remove('csalad@example.invalid')$$), 'ok', 'visszavonás: admin visszavon egy címet');
select is((select count(*)::int from public.household_members where user_id = 'cacacaca-0000-0000-0000-000000000000')
        + (select count(*)::int from private.allowed_emails where email = 'csalad@example.invalid'), 0, 'visszavonás: a cím és a tagság is megszűnt');
select is(pg_temp.q_as('cacacaca-0000-0000-0000-000000000000', 'select public.my_access() as a') -> 0 -> 'a' -> 'apps',
  '[]'::jsonb, 'visszavonás: a fiók semmihez nem fér hozzá');

select * from finish();
rollback;
