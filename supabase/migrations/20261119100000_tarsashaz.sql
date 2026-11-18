-- Társasházi elszámoló (tarsashaz.laszlobiri.com).
--
-- Négy lakás (fsz-1, fsz-2, em-3, em-4) osztozik a közös költségeken. Nevek nincsenek: a
-- felhasználók egy-egy lakáshoz tartoznak (allowed_emails.flat). Időszakonként tételek
-- (megnevezés, kategória, összeg, ki fizette, felosztás), a lezáráskor utalások.
--
-- Jogok:
--   * olvasás: aki a 'tarsashaz' oldalt megnyithatja (private.has_app);
--   * írás: csak a kezelő (admin vagy allowed_emails.th_manager), a th_* függvényeken át;
--   * utalás „megérkezett” jelölése: a kezelő, vagy az utaló / fogadó lakás lakója.
-- A táblákra közvetlen írási jog nincs; a függvények ellenőrzik az összegek egyezését is
-- (a lakásrészek összege = a tétel összege; lezáráskor az utalások kiadják az egyenlegeket).
--
-- Adat nincs a migrációban (tulajdoni hányad, létszám, tételek): a kezelő a felületen
-- állítja be, illetve egyszeri importtal tölti be (th_import).

-- ---------------------------------------------------------------------------
-- Az oldal kódja: 'elszamolas' → 'tarsashaz'
-- ---------------------------------------------------------------------------
create or replace function private.app_codes() returns text[]
language sql immutable set search_path = '' as $$
  select array['ebed', 'bevasarlas', 'gyakorlas', 'tarsashaz']::text[]
$$;

alter table private.allowed_emails drop constraint allowed_emails_apps_check;
update private.allowed_emails set apps = array_replace(apps, 'elszamolas', 'tarsashaz');
alter table private.allowed_emails add constraint allowed_emails_apps_check
  check (apps <@ array['ebed', 'bevasarlas', 'gyakorlas', 'tarsashaz']::text[]);

-- ---------------------------------------------------------------------------
-- Lakás és kezelői jog az engedélyezett címekhez
-- ---------------------------------------------------------------------------
alter table private.allowed_emails
  add column flat text check (flat in ('fsz-1', 'fsz-2', 'em-3', 'em-4')),
  add column th_manager boolean not null default false;

-- A belépett felhasználó lakása (csak ha a társasház oldalt megnyithatja).
create function private.th_my_flat() returns text
language sql stable security definer set search_path = '' as $$
  select a.flat from private.allowed_emails a
  join auth.users u on lower(u.email) = a.email
  where u.id = (select auth.uid()) and 'tarsashaz' = any (a.apps)
$$;

create function private.th_is_manager() returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_app('tarsashaz') and (private.is_admin() or exists (
    select 1 from private.allowed_emails a join auth.users u on lower(u.email) = a.email
    where u.id = (select auth.uid()) and a.th_manager))
$$;

create function private.th_can_read() returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_app('tarsashaz')
$$;

revoke all on function private.th_my_flat(), private.th_is_manager(), private.th_can_read() from public, anon;
grant execute on function private.th_my_flat(), private.th_is_manager(), private.th_can_read() to authenticated;

-- A kliensnek: { flat, manager }.
create function public.th_me() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('flat', private.th_my_flat(), 'manager', private.th_is_manager())
$$;
revoke all on function public.th_me() from public, anon;
grant execute on function public.th_me() to authenticated;

-- ---------------------------------------------------------------------------
-- Táblák
-- ---------------------------------------------------------------------------
create table public.th_flats (
  code  text primary key check (code in ('fsz-1', 'fsz-2', 'em-3', 'em-4')),
  share integer not null check (share between 0 and 10000),   -- tulajdoni hányad, tízezred
  sort  smallint not null
);

create table public.th_residents (
  flat       text not null references public.th_flats (code),
  valid_from date not null,
  count      smallint not null check (count between 0 and 20),
  primary key (flat, valid_from)
);

create table public.th_periods (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(btrim(name)) between 1 and 60),
  starts_on  date not null,
  ends_on    date,
  status     text not null default 'open' check (status in ('open', 'closed')),
  closed_at  timestamptz,
  note       text check (note is null or char_length(note) <= 300),
  created_at timestamptz not null default now()
);
create unique index th_periods_one_open on public.th_periods ((true)) where status = 'open';

-- Vízóra-leolvasás: a főmérő (nem kötelező) és a négy almérő.
create table public.th_readings (
  id         uuid primary key default gen_random_uuid(),
  read_on    date not null unique,
  main       numeric(10, 3) check (main >= 0),
  fsz1       numeric(10, 3) not null check (fsz1 >= 0),
  fsz2       numeric(10, 3) not null check (fsz2 >= 0),
  em3        numeric(10, 3) not null check (em3 >= 0),
  em4        numeric(10, 3) not null check (em4 >= 0),
  note       text check (note is null or char_length(note) <= 200),
  created_at timestamptz not null default now()
);

create table public.th_items (
  id           uuid primary key default gen_random_uuid(),
  period_id    uuid not null references public.th_periods (id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 1 and 80),
  category     text not null check (category in ('viz', 'csatorna', 'szemet', 'villany', 'egyeb')),
  amount       integer not null check (amount between -10000000 and 10000000),
  paid_by      text not null references public.th_flats (code),
  method       text not null check (method in ('hanyad', 'letszam', 'viz', 'egyenlo', 'kezi', 'atvett')),
  participants text[] not null check (cardinality(participants) between 1 and 4
                 and participants <@ array['fsz-1', 'fsz-2', 'em-3', 'em-4']::text[]),
  reading_from uuid references public.th_readings (id),
  reading_to   uuid references public.th_readings (id),
  note         text check (note is null or char_length(note) <= 200),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index th_items_period_idx on public.th_items (period_id);

-- A tétel lakásonkénti része (mentéskor rögzítve: a hányad vagy a létszám későbbi
-- változása a régi tételeket nem írja át).
create table public.th_item_shares (
  item_id uuid not null references public.th_items (id) on delete cascade,
  flat    text not null references public.th_flats (code),
  amount  integer not null,
  primary key (item_id, flat)
);

create table public.th_transfers (
  id         uuid primary key default gen_random_uuid(),
  period_id  uuid not null references public.th_periods (id) on delete cascade,
  from_flat  text not null references public.th_flats (code),
  to_flat    text not null references public.th_flats (code),
  amount     integer not null check (amount > 0),
  paid_at    timestamptz,
  check (from_flat <> to_flat)
);
create index th_transfers_period_idx on public.th_transfers (period_id);

-- ---------------------------------------------------------------------------
-- Jogok: olvasás a társasház oldal jogával, írás csak a függvényeken át.
-- ---------------------------------------------------------------------------
revoke all on public.th_flats, public.th_residents, public.th_periods, public.th_readings,
  public.th_items, public.th_item_shares, public.th_transfers from public, anon, authenticated;
grant select on public.th_flats, public.th_residents, public.th_periods, public.th_readings,
  public.th_items, public.th_item_shares, public.th_transfers to authenticated;

alter table public.th_flats        enable row level security;
alter table public.th_residents    enable row level security;
alter table public.th_periods      enable row level security;
alter table public.th_readings     enable row level security;
alter table public.th_items        enable row level security;
alter table public.th_item_shares  enable row level security;
alter table public.th_transfers    enable row level security;

create policy th_flats_select       on public.th_flats       for select to authenticated using (private.th_can_read());
create policy th_residents_select   on public.th_residents   for select to authenticated using (private.th_can_read());
create policy th_periods_select     on public.th_periods     for select to authenticated using (private.th_can_read());
create policy th_readings_select    on public.th_readings    for select to authenticated using (private.th_can_read());
create policy th_items_select       on public.th_items       for select to authenticated using (private.th_can_read());
create policy th_item_shares_select on public.th_item_shares for select to authenticated using (private.th_can_read());
create policy th_transfers_select   on public.th_transfers   for select to authenticated using (private.th_can_read());

-- ---------------------------------------------------------------------------
-- Írás: segédek
-- ---------------------------------------------------------------------------
create function private.th_require_manager() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.th_is_manager() then
    raise exception 'Csak a kezelő módosíthat.' using errcode = '42501';
  end if;
end $$;
revoke all on function private.th_require_manager() from public, anon;
grant execute on function private.th_require_manager() to authenticated;

create function private.th_require_open(pid uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.th_periods p where p.id = pid and p.status = 'open') then
    raise exception 'Az időszak le van zárva.' using errcode = '22023';
  end if;
end $$;
revoke all on function private.th_require_open(uuid) from public, anon;
grant execute on function private.th_require_open(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Beállítások: tulajdoni hányad, létszám
-- ---------------------------------------------------------------------------
-- p: {"fsz-1": 1911, "fsz-2": 1911, "em-3": 3089, "em-4": 3089}
create function public.th_save_flats(p jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare k text; tot integer := 0;
begin
  perform private.th_require_manager();
  for k in select jsonb_object_keys(p) loop
    if k not in ('fsz-1', 'fsz-2', 'em-3', 'em-4') then raise exception 'Ismeretlen lakás.' using errcode = '22023'; end if;
    tot := tot + (p ->> k)::integer;
  end loop;
  if (select count(*) from jsonb_object_keys(p)) <> 4 or tot <> 10000 then
    raise exception 'A négy lakás tulajdoni hányadának összege 10 000 legyen.' using errcode = '22023';
  end if;
  insert into public.th_flats (code, share, sort)
  select k2, (p ->> k2)::integer, array_position(array['fsz-1', 'fsz-2', 'em-3', 'em-4'], k2)
  from jsonb_object_keys(p) k2
  on conflict (code) do update set share = excluded.share;
end $$;

-- A létszám egy adott naptól: p_counts = {"fsz-1": 1, ...}
create function public.th_save_residents(p_valid_from date, p_counts jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare k text;
begin
  perform private.th_require_manager();
  if p_valid_from is null then raise exception 'Hiányzik a dátum.' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_counts) loop
    insert into public.th_residents (flat, valid_from, count) values (k, p_valid_from, (p_counts ->> k)::smallint)
    on conflict (flat, valid_from) do update set count = excluded.count;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Időszakok
-- ---------------------------------------------------------------------------
create function public.th_open_period(p_name text, p_starts_on date) returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare id uuid;
begin
  perform private.th_require_manager();
  if exists (select 1 from public.th_periods where status = 'open') then
    raise exception 'Már van nyitott időszak.' using errcode = '22023';
  end if;
  insert into public.th_periods (name, starts_on) values (btrim(p_name), p_starts_on) returning th_periods.id into id;
  return id;
end $$;

create function public.th_rename_period(p_id uuid, p_name text, p_starts_on date, p_ends_on date, p_note text) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.th_require_manager();
  update public.th_periods set name = btrim(p_name), starts_on = p_starts_on, ends_on = p_ends_on, note = nullif(btrim(p_note), '')
  where id = p_id;
end $$;

-- Lezárás: az utalások (p_transfers = [{from, to, amount}]) a kliens számítása; itt csak
-- ellenőrizzük, hogy minden lakás egyenlegét pontosan kiadják.
create function public.th_close_period(p_id uuid, p_transfers jsonb) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare f text; bal integer; net integer;
begin
  perform private.th_require_manager();
  perform private.th_require_open(p_id);
  for f in select code from public.th_flats loop
    select coalesce(sum(i.amount) filter (where i.paid_by = f), 0)
         - coalesce((select sum(s.amount) from public.th_item_shares s join public.th_items i2 on i2.id = s.item_id
                     where i2.period_id = p_id and s.flat = f), 0)
      into bal from public.th_items i where i.period_id = p_id;
    select coalesce(sum((t ->> 'amount')::integer) filter (where t ->> 'to' = f), 0)
         - coalesce(sum((t ->> 'amount')::integer) filter (where t ->> 'from' = f), 0)
      into net from jsonb_array_elements(coalesce(p_transfers, '[]')) t;
    if bal <> net then
      raise exception 'Az utalások nem adják ki a(z) % egyenlegét.', f using errcode = '22023';
    end if;
  end loop;
  insert into public.th_transfers (period_id, from_flat, to_flat, amount)
  select p_id, t ->> 'from', t ->> 'to', (t ->> 'amount')::integer
  from jsonb_array_elements(coalesce(p_transfers, '[]')) t where (t ->> 'amount')::integer > 0;
  update public.th_periods set status = 'closed', closed_at = now(),
    ends_on = coalesce(ends_on, current_date) where id = p_id;
end $$;

-- Újranyitás (hibajavításhoz): az utalások törlődnek. Ha már volt beérkezett utalás,
-- csak p_force = true-val.
create function public.th_reopen_period(p_id uuid, p_force boolean default false) returns integer
language plpgsql volatile security definer set search_path = '' as $$
declare paid integer;
begin
  perform private.th_require_manager();
  if exists (select 1 from public.th_periods where status = 'open') then
    raise exception 'Előbb zárd le a nyitott időszakot.' using errcode = '22023';
  end if;
  select count(*) into paid from public.th_transfers where period_id = p_id and paid_at is not null;
  if paid > 0 and not p_force then
    raise exception 'Ebben az időszakban már % utalás megérkezett.', paid using errcode = '22023';
  end if;
  delete from public.th_transfers where period_id = p_id;
  update public.th_periods set status = 'open', closed_at = null where id = p_id and status = 'closed';
  return paid;
end $$;

-- ---------------------------------------------------------------------------
-- Tételek. p = {id?, period_id, name, category, amount, paid_by, method, participants,
-- reading_from?, reading_to?, note?, shares: {"fsz-1": 123, ...}}
-- ---------------------------------------------------------------------------
create function public.th_save_item(p jsonb) returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare
  iid uuid := coalesce((p ->> 'id')::uuid, gen_random_uuid());
  pid uuid := (p ->> 'period_id')::uuid;
  amt integer := (p ->> 'amount')::integer;
  parts text[] := array(select jsonb_array_elements_text(p -> 'participants'));
  tot integer;
begin
  perform private.th_require_manager();
  perform private.th_require_open(pid);
  if exists (select 1 from public.th_items where id = iid and period_id <> pid) then
    raise exception 'A tétel másik időszakhoz tartozik.' using errcode = '22023';
  end if;
  if exists (select 1 from public.th_items i join public.th_periods pp on pp.id = i.period_id where i.id = iid and pp.status <> 'open') then
    raise exception 'Az időszak le van zárva.' using errcode = '22023';
  end if;
  select coalesce(sum(v::integer), 0) into tot from jsonb_each_text(p -> 'shares') as s(k, v);
  if tot <> amt then
    raise exception 'A lakásrészek összege (%) nem egyezik a tétel összegével (%).', tot, amt using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p -> 'shares') k where not k = any (parts)) then
    raise exception 'Csak beszálló lakásnak lehet része.' using errcode = '22023';
  end if;

  insert into public.th_items (id, period_id, name, category, amount, paid_by, method, participants, reading_from, reading_to, note)
  values (iid, pid, btrim(p ->> 'name'), p ->> 'category', amt, p ->> 'paid_by', p ->> 'method', parts,
          (p ->> 'reading_from')::uuid, (p ->> 'reading_to')::uuid, nullif(btrim(p ->> 'note'), ''))
  on conflict (id) do update set
    name = excluded.name, category = excluded.category, amount = excluded.amount, paid_by = excluded.paid_by,
    method = excluded.method, participants = excluded.participants, reading_from = excluded.reading_from,
    reading_to = excluded.reading_to, note = excluded.note, updated_at = now();

  delete from public.th_item_shares where item_id = iid;
  insert into public.th_item_shares (item_id, flat, amount)
  select iid, k, v::integer from jsonb_each_text(p -> 'shares') as s(k, v) where v::integer <> 0;
  return iid;
end $$;

create function public.th_delete_item(p_id uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.th_require_manager();
  perform private.th_require_open((select period_id from public.th_items where id = p_id));
  delete from public.th_items where id = p_id;
end $$;

-- ---------------------------------------------------------------------------
-- Vízóra-leolvasások
-- ---------------------------------------------------------------------------
create function public.th_save_reading(p jsonb) returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare rid uuid := coalesce((p ->> 'id')::uuid, gen_random_uuid());
begin
  perform private.th_require_manager();
  insert into public.th_readings (id, read_on, main, fsz1, fsz2, em3, em4, note)
  values (rid, (p ->> 'read_on')::date, (p ->> 'main')::numeric, (p ->> 'fsz1')::numeric, (p ->> 'fsz2')::numeric,
          (p ->> 'em3')::numeric, (p ->> 'em4')::numeric, nullif(btrim(p ->> 'note'), ''))
  on conflict (id) do update set read_on = excluded.read_on, main = excluded.main, fsz1 = excluded.fsz1,
    fsz2 = excluded.fsz2, em3 = excluded.em3, em4 = excluded.em4, note = excluded.note;
  return rid;
end $$;

create function public.th_delete_reading(p_id uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.th_require_manager();
  if exists (select 1 from public.th_items where reading_from = p_id or reading_to = p_id) then
    raise exception 'Ezt a leolvasást egy víz tétel használja.' using errcode = '22023';
  end if;
  delete from public.th_readings where id = p_id;
end $$;

-- ---------------------------------------------------------------------------
-- Utalás megérkezett / visszavonva: a kezelő, vagy az utaló vagy a fogadó lakás lakója.
-- ---------------------------------------------------------------------------
create function public.th_mark_transfer(p_id uuid, p_paid boolean) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare t public.th_transfers; me text := private.th_my_flat();
begin
  select * into t from public.th_transfers where id = p_id;
  if not found then raise exception 'Nincs ilyen utalás.' using errcode = '22023'; end if;
  if not (private.th_is_manager() or (me is not null and me in (t.from_flat, t.to_flat))) then
    raise exception 'Ezt az utalást nem jelölheted.' using errcode = '42501';
  end if;
  update public.th_transfers set paid_at = case when p_paid then coalesce(paid_at, now()) end where id = p_id;
end $$;

-- ---------------------------------------------------------------------------
-- Egyszeri import (régi időszakok), csak üres elszámolóba.
-- p = {flats: {...}, residents: [{valid_from, counts: {...}}], readings: [...],
--      periods: [{name, starts_on, ends_on, closed_at, note, items: [{...item, shares}], transfers: [...]}]}
-- A régi időszakok lezárva, az utalások beérkezettként kerülnek be.
-- ---------------------------------------------------------------------------
create function public.th_import(p jsonb) returns integer
language plpgsql volatile security definer set search_path = '' as $$
declare per jsonb; it jsonb; rs jsonb; pid uuid; iid uuid; n integer := 0; tot integer;
begin
  perform private.th_require_manager();
  if exists (select 1 from public.th_periods) then
    raise exception 'Az import csak üres elszámolóba lehetséges.' using errcode = '22023';
  end if;
  perform public.th_save_flats(p -> 'flats');
  for rs in select * from jsonb_array_elements(coalesce(p -> 'residents', '[]')) loop
    perform public.th_save_residents((rs ->> 'valid_from')::date, rs -> 'counts');
  end loop;
  for rs in select * from jsonb_array_elements(coalesce(p -> 'readings', '[]')) loop
    perform public.th_save_reading(rs);
  end loop;
  for per in select * from jsonb_array_elements(p -> 'periods') loop
    insert into public.th_periods (name, starts_on, ends_on, status, closed_at, note)
    values (per ->> 'name', (per ->> 'starts_on')::date, (per ->> 'ends_on')::date, 'closed',
            coalesce((per ->> 'closed_at')::timestamptz, now()), per ->> 'note')
    returning id into pid;
    for it in select * from jsonb_array_elements(per -> 'items') loop
      select coalesce(sum(v::integer), 0) into tot from jsonb_each_text(it -> 'shares') as s(k, v);
      if tot <> (it ->> 'amount')::integer then
        raise exception 'Import: a(z) „%” tétel részei nem adják ki az összeget.', it ->> 'name' using errcode = '22023';
      end if;
      insert into public.th_items (id, period_id, name, category, amount, paid_by, method, participants, note)
      values (gen_random_uuid(), pid, it ->> 'name', it ->> 'category', (it ->> 'amount')::integer, it ->> 'paid_by',
              coalesce(it ->> 'method', 'atvett'), array(select jsonb_array_elements_text(it -> 'participants')), it ->> 'note')
      returning id into iid;
      insert into public.th_item_shares (item_id, flat, amount)
      select iid, k, v::integer from jsonb_each_text(it -> 'shares') as s(k, v) where v::integer <> 0;
      n := n + 1;
    end loop;
    insert into public.th_transfers (period_id, from_flat, to_flat, amount, paid_at)
    select pid, t ->> 'from', t ->> 'to', (t ->> 'amount')::integer, coalesce((per ->> 'closed_at')::timestamptz, now())
    from jsonb_array_elements(coalesce(per -> 'transfers', '[]')) t;
  end loop;
  return n;
end $$;

revoke all on function public.th_save_flats(jsonb), public.th_save_residents(date, jsonb), public.th_open_period(text, date),
  public.th_rename_period(uuid, text, date, date, text), public.th_close_period(uuid, jsonb), public.th_reopen_period(uuid, boolean),
  public.th_save_item(jsonb), public.th_delete_item(uuid), public.th_save_reading(jsonb), public.th_delete_reading(uuid),
  public.th_mark_transfer(uuid, boolean), public.th_import(jsonb) from public, anon;
grant execute on function public.th_save_flats(jsonb), public.th_save_residents(date, jsonb), public.th_open_period(text, date),
  public.th_rename_period(uuid, text, date, date, text), public.th_close_period(uuid, jsonb), public.th_reopen_period(uuid, boolean),
  public.th_save_item(jsonb), public.th_delete_item(uuid), public.th_save_reading(jsonb), public.th_delete_reading(uuid),
  public.th_mark_transfer(uuid, boolean), public.th_import(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: a lakás és a kezelői jog a hozzáférések között.
-- ---------------------------------------------------------------------------
drop function public.admin_access_list();
create function public.admin_access_list()
returns table (
  email           text,
  apps            text[],
  in_household    boolean,
  app_role        text,
  note            text,
  display_name    text,
  has_account     boolean,
  last_sign_in_at timestamptz,
  added_at        timestamptz,
  flat            text,
  th_manager      boolean
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then
    raise exception 'Csak admin.' using errcode = '42501';
  end if;
  return query
    select a.email, a.apps,
           a.household_id is not null and a.household_id = private.admin_household(),
           a.app_role, a.note, p.display_name, u.id is not null, u.last_sign_in_at, a.created_at, a.flat, a.th_manager
    from private.allowed_emails a
    left join auth.users u on lower(u.email) = a.email and not u.is_anonymous
    left join public.profiles p on p.id = u.id
    order by a.created_at, a.email;
end
$$;
revoke all on function public.admin_access_list() from public, anon;
grant execute on function public.admin_access_list() to authenticated;

-- A lakás és a kezelői jog külön függvénnyel (az admin_access_set változatlan marad).
create function public.admin_set_flat(p_email text, p_flat text, p_manager boolean default false) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not private.is_admin() then
    raise exception 'Csak admin.' using errcode = '42501';
  end if;
  if p_flat is not null and p_flat not in ('fsz-1', 'fsz-2', 'em-3', 'em-4') then
    raise exception 'Ismeretlen lakás.' using errcode = '22023';
  end if;
  update private.allowed_emails set flat = p_flat, th_manager = coalesce(p_manager, false), updated_at = now()
  where email = lower(btrim(p_email));
  if not found then raise exception 'Nincs ilyen cím.' using errcode = '22023'; end if;
end $$;
revoke all on function public.admin_set_flat(text, text, boolean) from public, anon;
grant execute on function public.admin_set_flat(text, text, boolean) to authenticated;
