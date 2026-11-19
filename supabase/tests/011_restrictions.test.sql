-- Korlátok, átfogóan: minden szerkesztő függvény csak az adminnak (a társasházban a
-- társasház oldal jogával is), a táblákra közvetlen írási jog nincs, az anon semmit nem hívhat.
-- A függvényeket az adatbázisból kérdezi le, így egy később felvett függvény is ellenőrzés alá esik.
--
-- Szereplők (kitalált adatok):
--   ADM: admin, a társasház oldallal (em-4)
--   AN:  admin, de a társasház oldal nélkül
--   L:   lakó (fsz-1), csak a társasház oldallal
--   CS:  családtag (nem admin), a családi oldalakkal
--   T:   gyerek tablet (névtelen fiók)

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(12);

insert into public.households (id, name) values ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás');
insert into private.allowed_emails (email, household_id, app_role, apps, flat) values
  ('adm@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000', 'admin', '{bevasarlas,gyakorlas,tarsashaz}', 'em-4'),
  ('an@example.invalid',  null, 'admin', '{ebed}', null),
  ('l@example.invalid',   null, 'user',  '{tarsashaz}', 'fsz-1'),
  ('cs@example.invalid',  'aaaaaaaa-0000-0000-0000-000000000000', 'user', '{bevasarlas,gyakorlas}', null);
insert into auth.users (id, email) values
  ('adadadad-0000-0000-0000-000000000000', 'adm@example.invalid'),
  ('a0a0a0a0-0000-0000-0000-000000000000', 'an@example.invalid'),
  ('1e1e1e1e-0000-0000-0000-000000000000', 'l@example.invalid'),
  ('c5c5c5c5-0000-0000-0000-000000000000', 'cs@example.invalid');
insert into auth.users (id, is_anonymous) values ('7a7a7a7a-0000-0000-0000-000000000000', true);

-- Minden szerkesztő th_* függvény (a th_me és az utalás-jelölés kivételével) hívása NULL
-- argumentumokkal: a jogellenőrzés az első lépés, tehát 42501-et kell adnia.
create function pg_temp.th_denied_for(uid uuid) returns text[]
language plpgsql as $$
declare f record; bad text[] := '{}'; res text;
begin
  for f in select p.proname, p.pronargs from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.proname like 'th\_%'
             and p.proname not in ('th_me', 'th_mark_transfer') loop
    res := pg_temp.err_as(uid, format('select public.%I(%s)', f.proname, array_to_string(array_fill('null'::text, array[f.pronargs]), ', ')));
    if res <> '42501' then bad := bad || (f.proname || ': ' || res); end if;
  end loop;
  return bad;
end $$;

create function pg_temp.admin_denied_for(uid uuid) returns text[]
language plpgsql as $$
declare f record; bad text[] := '{}'; res text;
begin
  for f in select p.proname, p.pronargs from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.proname like 'admin\_%' loop
    res := pg_temp.err_as(uid, format('select * from public.%I(%s)', f.proname, array_to_string(array_fill('null'::text, array[f.pronargs]), ', ')));
    if res <> '42501' then bad := bad || (f.proname || ': ' || res); end if;
  end loop;
  return bad;
end $$;

select ok((select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'th\_%') >= 10, 'van mit ellenőrizni (th_* függvények)');

-- ---------------------------------------------------------------- társasház: csak az admin
select is(pg_temp.th_denied_for('1e1e1e1e-0000-0000-0000-000000000000'), '{}'::text[], 'lakó: egyik szerkesztő függvényt sem hívhatja');
select is(pg_temp.th_denied_for('c5c5c5c5-0000-0000-0000-000000000000'), '{}'::text[], 'családtag (nem admin): egyik szerkesztő függvényt sem hívhatja');
select is(pg_temp.th_denied_for('a0a0a0a0-0000-0000-0000-000000000000'), '{}'::text[], 'admin a társasház oldal nélkül: nem szerkeszthet');
select is(pg_temp.th_denied_for('7a7a7a7a-0000-0000-0000-000000000000'), '{}'::text[], 'gyerek tablet: nem szerkeszthet');
select is(pg_temp.q_as('adadadad-0000-0000-0000-000000000000', 'select public.th_me() as a') -> 0 -> 'a' -> 'manager', 'true'::jsonb, 'admin a társasház oldallal: kezelő');
select is(pg_temp.q_as('1e1e1e1e-0000-0000-0000-000000000000', 'select public.th_me() as a') -> 0 -> 'a' -> 'manager', 'false'::jsonb, 'lakó: nem kezelő');

-- ---------------------------------------------------------------- admin függvények: csak az admin
select is(pg_temp.admin_denied_for('1e1e1e1e-0000-0000-0000-000000000000'), '{}'::text[], 'lakó: egyik admin függvényt sem hívhatja');
select is(pg_temp.admin_denied_for('c5c5c5c5-0000-0000-0000-000000000000'), '{}'::text[], 'családtag (nem admin): egyik admin függvényt sem hívhatja');

-- ---------------------------------------------------------------- táblák és anon
select is((select coalesce(array_agg(table_name || ':' || privilege_type order by table_name, privilege_type), '{}')
           from information_schema.role_table_grants
           where grantee = 'authenticated' and table_schema = 'public' and table_name like 'th\_%' and privilege_type <> 'SELECT'),
  '{}'::text[], 'társasház táblák: közvetlen írási jog senkinek');
select is((select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p
           where p.pronamespace = 'public'::regnamespace and (p.proname like 'th\_%' or p.proname like 'admin\_%')
             and has_function_privilege('anon', p.oid, 'EXECUTE')),
  '{}'::text[], 'anon: egyik társasház és admin függvényt sem hívhatja');
select is((select count(*)::int from information_schema.columns where table_schema = 'private' and table_name = 'allowed_emails' and column_name = 'th_manager'),
  0, 'külön kezelői jog nincs (csak az admin kezelő)');

select * from finish();
rollback;
