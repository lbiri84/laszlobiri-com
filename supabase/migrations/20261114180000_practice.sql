-- 3. fázis: gyakorló oldal – gyerekprofilok, eredmények, jelvények, gyerek mód.
-- Terv: docs/backend-terv.md („Gyakorló oldal”, „Gyerek mód: eszközfiók”, 3. fázis).
--
-- Adatvédelem (kiskorúak): a gyerekről csak becenév és ikonkód; az eredmény
-- számokból és kódokból áll, szabad szöveg nélkül. A gyereknek nincs fiókja: a
-- saját tabletje egy névtelen, párosított eszközfiókkal (devices) éri el a hozzá
-- rendelt profilokat, és semmi mást.

-- ---------------------------------------------------------------------------
-- Gyerekprofilok
-- ---------------------------------------------------------------------------
create table public.pupils (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  nickname     text not null check (char_length(btrim(nickname)) between 1 and 20),
  avatar       text not null default 'fox'
               check (avatar in ('fox', 'owl', 'cat', 'bear', 'frog', 'bee', 'rabbit', 'turtle')),
  created_at   timestamptz not null default now()
);
create unique index pupils_household_nickname on public.pupils (household_id, lower(btrim(nickname)));

-- ---------------------------------------------------------------------------
-- Eredmények: egy sor egy befejezett kör vagy minijáték. Csak hozzáfűzés.
-- ---------------------------------------------------------------------------
create table public.results (
  id          uuid primary key default gen_random_uuid(),     -- a kliens generálja (offline, ismétlés)
  pupil_id    uuid not null references public.pupils (id) on delete cascade,
  kind        text not null check (kind in ('round', 'hangman', 'wordsearch')),
  topic       text check (topic ~ '^[a-z0-9]{1,32}$'),
  score       smallint not null default 0 check (score between 0 and 10),
  best_streak smallint not null default 0 check (best_streak between 0 and 10),
  answered    smallint not null default 0 check (answered between 0 and 10),
  correct     smallint not null default 0 check (correct between 0 and answered),
  points      smallint not null default 0 check (points between 0 and 200),
  created_at  timestamptz not null default now(),
  recorded_by uuid references auth.users (id) on delete set null,
  constraint results_round_has_topic check (kind <> 'round' or topic is not null)
);
create index results_pupil_created_idx on public.results (pupil_id, created_at desc);

-- A szerver rögzíti, ki írta; az időpont a kliensé (offline gyakorlásnál a játék
-- ideje számít a napi sorozathoz), de nem lehet a jövőben vagy 30 napnál régebben.
create function private.results_stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.recorded_by := (select auth.uid());
  if new.created_at is null or new.created_at > now() + interval '5 minutes'
     or new.created_at < now() - interval '30 days' then
    new.created_at := now();
  end if;
  return new;
end $$;
revoke all on function private.results_stamp() from public, anon, authenticated;
create trigger results_stamp before insert on public.results
  for each row execute function private.results_stamp();

create table public.pupil_badges (
  pupil_id  uuid not null references public.pupils (id) on delete cascade,
  badge_id  text not null check (badge_id ~ '^[a-z0-9-]{1,32}$'),
  earned_at timestamptz not null default now(),
  primary key (pupil_id, badge_id)
);

-- ---------------------------------------------------------------------------
-- Gyerek mód: párosított eszközök
-- ---------------------------------------------------------------------------
create table public.devices (
  user_id      uuid primary key references auth.users (id) on delete cascade,   -- a névtelen fiók
  household_id uuid not null references public.households (id) on delete cascade,
  label        text not null check (char_length(btrim(label)) between 1 and 30),
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create table public.device_pupils (
  device_user_id uuid not null references public.devices (user_id) on delete cascade,
  pupil_id       uuid not null references public.pupils (id) on delete cascade,
  primary key (device_user_id, pupil_id)
);

-- Egyszer használható párosító kódok. A kód maga nincs tárolva, csak a hash-e.
create table private.device_pairings (
  code_hash    text primary key,
  household_id uuid not null references public.households (id) on delete cascade,
  pupil_ids    uuid[] not null check (cardinality(pupil_ids) between 1 and 10),
  label        text not null,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '10 minutes',
  used_at      timestamptz
);
alter table private.device_pairings enable row level security;
revoke all on private.device_pairings from public, anon, authenticated;

-- Sikertelen beváltási kísérletek fiókonként (találgatás ellen).
create table private.pairing_attempts (
  user_id  uuid primary key references auth.users (id) on delete cascade,
  failures integer not null default 0
);
alter table private.pairing_attempts enable row level security;
revoke all on private.pairing_attempts from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Segédfüggvények
-- ---------------------------------------------------------------------------
create function private.pupil_household(pid uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select p.household_id from public.pupils p where p.id = pid
$$;

create function private.is_device_for(pid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.device_pupils dp
    where dp.device_user_id = (select auth.uid()) and dp.pupil_id = pid
  )
$$;

revoke all on function private.pupil_household(uuid), private.is_device_for(uuid) from public, anon;
grant execute on function private.pupil_household(uuid), private.is_device_for(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Jogok
-- ---------------------------------------------------------------------------
revoke all on public.pupils, public.results, public.pupil_badges, public.devices, public.device_pupils
  from public, anon, authenticated;

grant select, delete on public.pupils to authenticated;
grant insert (id, household_id, nickname, avatar) on public.pupils to authenticated;
grant update (nickname, avatar) on public.pupils to authenticated;

grant select, delete on public.results to authenticated;
grant insert (id, pupil_id, kind, topic, score, best_streak, answered, correct, points, created_at)
  on public.results to authenticated;

grant select, delete on public.pupil_badges to authenticated;
grant insert (pupil_id, badge_id, earned_at) on public.pupil_badges to authenticated;

grant select, delete on public.devices to authenticated;
grant update (label, last_seen_at) on public.devices to authenticated;
grant select on public.device_pupils to authenticated;

alter table public.pupils        enable row level security;
alter table public.results       enable row level security;
alter table public.pupil_badges  enable row level security;
alter table public.devices       enable row level security;
alter table public.device_pupils enable row level security;

-- pupils: a szülő mindent; az eszköz csak a hozzá rendelt profilokat látja.
create policy pupils_select on public.pupils for select to authenticated
  using (private.is_parent(household_id) or private.is_device_for(id));
create policy pupils_insert on public.pupils for insert to authenticated
  with check (private.is_parent(household_id));
create policy pupils_update on public.pupils for update to authenticated
  using (private.is_parent(household_id)) with check (private.is_parent(household_id));
create policy pupils_delete on public.pupils for delete to authenticated
  using (private.is_parent(household_id));

-- results, pupil_badges: szülő, vagy a gyerekhez rendelt eszköz; törölni csak a szülő.
create policy results_select on public.results for select to authenticated
  using (private.is_parent(private.pupil_household(pupil_id)) or private.is_device_for(pupil_id));
create policy results_insert on public.results for insert to authenticated
  with check (private.is_parent(private.pupil_household(pupil_id)) or private.is_device_for(pupil_id));
create policy results_delete on public.results for delete to authenticated
  using (private.is_parent(private.pupil_household(pupil_id)));

create policy pupil_badges_select on public.pupil_badges for select to authenticated
  using (private.is_parent(private.pupil_household(pupil_id)) or private.is_device_for(pupil_id));
create policy pupil_badges_insert on public.pupil_badges for insert to authenticated
  with check (private.is_parent(private.pupil_household(pupil_id)) or private.is_device_for(pupil_id));
create policy pupil_badges_delete on public.pupil_badges for delete to authenticated
  using (private.is_parent(private.pupil_household(pupil_id)));

-- devices: a szülő látja és visszavonhatja; az eszköz a saját sorát látja, és a last_seen_at-et frissíti.
create policy devices_select on public.devices for select to authenticated
  using (private.is_parent(household_id) or user_id = (select auth.uid()));
create policy devices_update_parent on public.devices for update to authenticated
  using (private.is_parent(household_id)) with check (private.is_parent(household_id));
create policy devices_update_self on public.devices for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy devices_delete on public.devices for delete to authenticated
  using (private.is_parent(household_id));

create policy device_pupils_select on public.device_pupils for select to authenticated
  using (device_user_id = (select auth.uid())
         or private.is_parent((select d.household_id from public.devices d where d.user_id = device_user_id)));

-- Az eszköz a címkét nem írhatja át, csak a last_seen_at-et.
create function private.devices_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.user_id = (select auth.uid()) and new.label is distinct from old.label then
    new.label := old.label;
  end if;
  return new;
end $$;
revoke all on function private.devices_guard() from public, anon, authenticated;
create trigger devices_guard before update on public.devices
  for each row execute function private.devices_guard();

-- ---------------------------------------------------------------------------
-- Párosítás
-- ---------------------------------------------------------------------------

-- A kód: 8 karakter egy félreolvashatatlan ábécéből (32^8 ≈ 10^12), 10 percig él.
create function public.create_pairing(p_pupils uuid[], p_label text) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  hid  uuid;
  raw  bytea := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
  code text := '';
  i    int;
begin
  if p_pupils is null or cardinality(p_pupils) = 0 then
    raise exception 'legalább egy gyerek kell' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_label, ''))) not between 1 and 30 then
    raise exception 'az eszköz neve 1–30 karakter' using errcode = '22023';
  end if;
  select distinct p.household_id into hid from public.pupils p where p.id = any (p_pupils);
  if hid is null
     or (select count(distinct p.household_id) from public.pupils p where p.id = any (p_pupils)) <> 1
     or (select count(*) from public.pupils p where p.id = any (p_pupils)) <> cardinality(p_pupils)
     or not private.is_parent(hid) then
    raise exception 'nincs jogosultság' using errcode = '42501';
  end if;
  -- A bájtok 0–5. és 10–15. helye teljesen véletlen (a verzió- és variáns-bitek kimaradnak).
  foreach i in array array[0, 1, 2, 3, 4, 5, 10, 11] loop
    code := code || substr(alphabet, (get_byte(raw, i) % 32) + 1, 1);
  end loop;
  insert into private.device_pairings (code_hash, household_id, pupil_ids, label, created_by)
  values (encode(sha256(convert_to(code, 'UTF8')), 'hex'), hid, p_pupils, btrim(p_label), (select auth.uid()));
  return substr(code, 1, 4) || '-' || substr(code, 5, 4);
end $$;

-- Beváltás: csak névtelen, még párosítatlan fiók; egyszer használható, lejáró kód.
-- Eredmény: 'ok', vagy 'invalid' (hibás / lejárt / felhasznált kód). A hibás kódnál
-- szándékosan nem dob kivételt: a kivétel a próbálkozás-számlálót is visszagörgetné.
create function public.claim_pairing(p_code text) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  me   uuid := (select auth.uid());
  norm text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  p    private.device_pairings;
begin
  if me is null or not exists (select 1 from auth.users u where u.id = me and u.is_anonymous) then
    raise exception 'csak gyerek tablet (névtelen fiók) párosítható' using errcode = '42501';
  end if;
  if exists (select 1 from public.devices d where d.user_id = me) then
    raise exception 'ez az eszköz már párosítva van' using errcode = '22023';
  end if;
  if coalesce((select a.failures from private.pairing_attempts a where a.user_id = me), 0) >= 10 then
    raise exception 'túl sok hibás próbálkozás' using errcode = '42501';
  end if;

  select * into p from private.device_pairings d
  where d.code_hash = encode(sha256(convert_to(norm, 'UTF8')), 'hex')
    and d.used_at is null and d.expires_at > now()
  for update;
  if not found then
    insert into private.pairing_attempts (user_id, failures) values (me, 1)
    on conflict (user_id) do update set failures = private.pairing_attempts.failures + 1;
    return 'invalid';
  end if;

  update private.device_pairings set used_at = now() where code_hash = p.code_hash;
  insert into public.devices (user_id, household_id, label, created_by)
  values (me, p.household_id, p.label, p.created_by);
  insert into public.device_pupils (device_user_id, pupil_id)
  select me, pid from unnest(p.pupil_ids) as pid
  where exists (select 1 from public.pupils x where x.id = pid and x.household_id = p.household_id);
  return 'ok';
end $$;

revoke all on function public.create_pairing(uuid[], text), public.claim_pairing(text) from public, anon;
grant execute on function public.create_pairing(uuid[], text), public.claim_pairing(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Takarítás (naponta): párosítatlan névtelen fiókok 24 óra után, lejárt kódok.
-- A visszavont eszköz (devices sor törölve) névtelen fiókja is itt törlődik.
-- ---------------------------------------------------------------------------
create function private.cleanup_devices() returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from auth.users u
  where u.is_anonymous
    and u.created_at < now() - interval '24 hours'
    and not exists (select 1 from public.devices d where d.user_id = u.id);
  delete from private.device_pairings where expires_at < now() - interval '1 day';
end $$;
revoke all on function private.cleanup_devices() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('laszlobiri-devices-cleanup', '23 3 * * *', 'select private.cleanup_devices()');
  end if;
end $$;
