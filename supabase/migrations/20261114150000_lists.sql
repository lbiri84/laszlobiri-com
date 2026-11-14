-- 2. fázis: közös bevásárlólista.
-- Terv: docs/backend-terv.md („Bevásárlólista”, 2. szakasz, 2. fázis).
--
-- Háztartásonként egy lista (lists), a tételek (items) soft delete-tel, hogy a
-- törlés is szinkronizálódjon, és a „gyakran vett” javaslatok (item_history).

-- ---------------------------------------------------------------------------
-- lists: háztartásonként pontosan egy
-- ---------------------------------------------------------------------------
create table public.lists (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  name         text not null default 'Közös lista' check (char_length(name) between 1 and 60),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
-- Döntés: egy közös lista háztartásonként. Több listához ezt az indexet kell elvenni.
create unique index lists_one_per_household on public.lists (household_id);

create function private.create_household_list() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.lists (household_id) values (new.id) on conflict do nothing;
  return new;
end $$;
revoke all on function private.create_household_list() from public, anon, authenticated;

create trigger on_household_created
  after insert on public.households
  for each row execute function private.create_household_list();

-- A már meglévő háztartások listája.
insert into public.lists (household_id)
select h.id from public.households h
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- items
-- ---------------------------------------------------------------------------
create table public.items (
  id         uuid primary key default gen_random_uuid(),   -- a kliens generálja (offline létrehozás)
  list_id    uuid not null references public.lists (id) on delete cascade,
  name       text not null check (char_length(btrim(name)) between 1 and 80),
  -- A név kisbetűs, ékezet nélküli alakja (a kliens fold() függvénye). Egyedi a listán
  -- belül az élő tételek között; törléskor null, így a törölt tétel újra felvehető.
  name_key   text check (name_key is null or (char_length(name_key) between 1 and 80 and name_key = lower(name_key))),
  qty        text not null default '' check (char_length(qty) <= 30),
  cat        text not null default 'egyeb'
             check (cat in ('zold', 'tej', 'hus', 'pek', 'szaraz', 'ital', 'fagy', 'haztartas', 'egyeb')),
  done       boolean not null default false,
  added_at   timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint items_live_name_key_unique unique (list_id, name_key),
  constraint items_live_has_key check (deleted_at is not null or name_key is not null)
);
create index items_list_updated_idx on public.items (list_id, updated_at);

-- A szerver állítja: ki és mikor; a kliens ezeket nem írhatja felül.
create function private.items_stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := (select auth.uid());
  else
    new.created_by := old.created_by;
    new.list_id    := old.list_id;      -- tétel nem mozgatható át másik listába
    new.added_at   := old.added_at;
  end if;
  new.updated_by := (select auth.uid());
  new.updated_at := now();
  if new.deleted_at is not null then
    new.name_key := null;
  end if;
  return new;
end $$;
revoke all on function private.items_stamp() from public, anon, authenticated;

create trigger items_stamp
  before insert or update on public.items
  for each row execute function private.items_stamp();

-- ---------------------------------------------------------------------------
-- item_history: a „gyakran vett” javaslatok, háztartásonként közösen
-- ---------------------------------------------------------------------------
create table public.item_history (
  household_id uuid not null references public.households (id) on delete cascade,
  name_key     text not null check (char_length(name_key) between 1 and 80 and name_key = lower(name_key)),
  name         text not null check (char_length(btrim(name)) between 1 and 80),
  cat          text not null
               check (cat in ('zold', 'tej', 'hus', 'pek', 'szaraz', 'ital', 'fagy', 'haztartas', 'egyeb')),
  count        integer not null default 1 check (count >= 0),
  last_used    timestamptz not null default now(),
  primary key (household_id, name_key)
);
create index item_history_rank_idx on public.item_history (household_id, count desc, last_used desc);

-- ---------------------------------------------------------------------------
-- Segédfüggvény a policykhoz
-- ---------------------------------------------------------------------------
create function private.list_household(lid uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select l.household_id from public.lists l where l.id = lid
$$;
revoke all on function private.list_household(uuid) from public, anon;
grant execute on function private.list_household(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Jogok
-- ---------------------------------------------------------------------------
revoke all on public.lists, public.items, public.item_history from public, anon, authenticated;

grant select on public.lists to authenticated;
grant update (name) on public.lists to authenticated;

grant select on public.items to authenticated;
grant insert (id, list_id, name, name_key, qty, cat, done, added_at) on public.items to authenticated;
grant update (name, name_key, qty, cat, done, deleted_at) on public.items to authenticated;
-- Valódi törlés nincs a kliensből: soft delete (deleted_at), a takarítás 30 nap után.

grant select on public.item_history to authenticated;
-- Írás csak a bump_history függvényen át.

alter table public.lists        enable row level security;
alter table public.items        enable row level security;
alter table public.item_history enable row level security;

create policy lists_select on public.lists
  for select to authenticated using (private.is_member(household_id));
create policy lists_update on public.lists
  for update to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));

create policy items_select on public.items
  for select to authenticated using (private.is_member(private.list_household(list_id)));
create policy items_insert on public.items
  for insert to authenticated with check (private.is_member(private.list_household(list_id)));
create policy items_update on public.items
  for update to authenticated
  using (private.is_member(private.list_household(list_id)))
  with check (private.is_member(private.list_household(list_id)));

create policy item_history_select on public.item_history
  for select to authenticated using (private.is_member(household_id));

-- ---------------------------------------------------------------------------
-- bump_history: egy név használatának számlálása (egyidejű növelésnél sem vész el)
-- ---------------------------------------------------------------------------
create function public.bump_history(p_household uuid, p_name_key text, p_name text, p_cat text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_member(p_household) then
    raise exception 'nincs jogosultság' using errcode = '42501';
  end if;
  insert into public.item_history (household_id, name_key, name, cat)
  values (p_household, p_name_key, p_name, p_cat)
  on conflict (household_id, name_key) do update
    set count = public.item_history.count + 1,
        name = excluded.name,
        cat = excluded.cat,
        last_used = now();
end $$;
revoke all on function public.bump_history(uuid, text, text, text) from public, anon;
grant execute on function public.bump_history(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime: a lista és a tételek változásai (a postgres_changes alkalmazza az RLS-t)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.lists, public.items;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Takarítás: a 30 napnál régebben törölt tételek végleges törlése, naponta.
-- A pg_cron a Supabase-en elérhető; helyi teszten (sima Postgres) kimarad.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule(
      'laszlobiri-items-purge',
      '17 3 * * *',
      $job$delete from public.items where deleted_at < now() - interval '30 days'$job$
    );
  end if;
end $$;
