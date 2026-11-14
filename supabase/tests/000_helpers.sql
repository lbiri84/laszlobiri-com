-- Közös teszt-segédfüggvények. Minden tesztfájl elején \ir-rel töltődik be,
-- a pg_temp sémába, így a tranzakció végén eltűnnek.
--
-- A lekérdezéseket a megadott felhasználóként futtatják (role + JWT claims),
-- de a pgTAP állítások postgresként futnak. uid = null: anon szerep.

create or replace function pg_temp.become(uid uuid) returns void
language plpgsql as $$
begin
  if uid is null then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    execute 'set local role anon';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', uid, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
  end if;
end $$;

create or replace function pg_temp.unbecome() returns void
language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Lekérdezés eredménye jsonb tömbként.
create or replace function pg_temp.q_as(uid uuid, q text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.become(uid);
  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', q) into r;
  perform pg_temp.unbecome();
  return r;
end $$;

-- Sorok száma a lekérdezésben.
create or replace function pg_temp.count_as(uid uuid, q text) returns int
language sql as $$ select jsonb_array_length(pg_temp.q_as(uid, q)) $$;

-- DML által érintett sorok száma.
create or replace function pg_temp.n_as(uid uuid, q text) returns int
language plpgsql as $$
declare n int;
begin
  perform pg_temp.become(uid);
  execute q;
  get diagnostics n = row_count;
  perform pg_temp.unbecome();
  return n;
end $$;

-- 'ok', vagy a hiba SQLSTATE kódja (pl. 42501 = nincs jog / RLS).
create or replace function pg_temp.err_as(uid uuid, q text) returns text
language plpgsql as $$
begin
  begin
    perform pg_temp.become(uid);
    execute q;
    perform pg_temp.unbecome();
    return 'ok';
  exception when others then
    -- a belső blokk visszagörgetése a role-t is visszaállítja
    return sqlstate;
  end;
end $$;
