-- 1. fázis: felhasználók, háztartás, allowlist.
-- Terv: docs/backend-terv.md (1–3. szakasz).
--
-- Elvek:
--   * Minden public táblán RLS, az anon szerep semmilyen jogot nem kap.
--   * Az authenticated szerep csak a felsorolt műveleteket és oszlopokat kapja.
--   * A private séma nincs közzétéve a Data API-n; az allowlist ott van.

-- ---------------------------------------------------------------------------
-- private séma
-- ---------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
-- A policykban használt segédfüggvényekhez kell a usage (a séma ettől még nincs közzétéve).
grant usage on schema private to authenticated;
-- Az auth hooknak és triggernek.
grant usage on schema private to supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- Táblák
-- ---------------------------------------------------------------------------
create table public.households (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 60),
  created_at timestamptz not null default now()
);

create table private.allowed_emails (
  -- Kisbetűvel tárolva; az összehasonlítás lower()-rel történik.
  email          text primary key check (email = lower(email) and email like '%_@_%'),
  household_id   uuid references public.households (id) on delete set null,
  household_role text not null default 'parent' check (household_role in ('parent')),
  app_role       text not null default 'user' check (app_role in ('admin', 'user')),
  note           text,
  created_at     timestamptz not null default now()
);

create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40),
  app_role     text not null default 'user' check (app_role in ('admin', 'user')),
  created_at   timestamptz not null default now()
);

create table public.household_members (
  household_id uuid not null references public.households (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  -- Egyetlen szerep van; az oszlop egy későbbi szűkebb szerep miatt marad.
  role         text not null default 'parent' check (role in ('parent')),
  created_at   timestamptz not null default now(),
  primary key (household_id, user_id)
);
create index household_members_user_idx on public.household_members (user_id);

-- ---------------------------------------------------------------------------
-- Jogok: előbb mindent visszavonunk (a Supabase alapból mindent megad), aztán
-- csak a szükségeset adjuk vissza.
-- ---------------------------------------------------------------------------
revoke all on public.households, public.profiles, public.household_members from public, anon, authenticated;
revoke all on private.allowed_emails from public, anon, authenticated;

grant select on public.households, public.profiles, public.household_members to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant update (name) on public.households to authenticated;

alter table public.households        enable row level security;
alter table public.profiles          enable row level security;
alter table public.household_members enable row level security;
alter table private.allowed_emails   enable row level security;  -- policy nincs: kliensből elérhetetlen

-- ---------------------------------------------------------------------------
-- Segédfüggvények a policykhoz. security definer: így a household_members saját
-- RLS-e nem okoz rekurziót. Csak a hívóra vonatkozó igen/nem választ adnak.
-- ---------------------------------------------------------------------------
create function private.is_member(hid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = hid and m.user_id = (select auth.uid())
  )
$$;

create function private.is_parent(hid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = hid and m.user_id = (select auth.uid()) and m.role = 'parent'
  )
$$;

create function private.shares_household(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.household_members me
    join public.household_members them on them.household_id = me.household_id
    where me.user_id = (select auth.uid()) and them.user_id = other
  )
$$;

revoke all on function private.is_member(uuid), private.is_parent(uuid), private.shares_household(uuid) from public, anon;
grant execute on function private.is_member(uuid), private.is_parent(uuid), private.shares_household(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Policyk
-- ---------------------------------------------------------------------------
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or private.shares_household(id));

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy households_select on public.households
  for select to authenticated
  using (private.is_member(id));

create policy households_update on public.households
  for update to authenticated
  using (private.is_parent(id))
  with check (private.is_parent(id));

create policy household_members_select on public.household_members
  for select to authenticated
  using (private.is_member(household_id));

-- ---------------------------------------------------------------------------
-- Allowlist, 1. réteg: "Before User Created" auth hook.
-- Bekötés: Dashboard → Authentication → Hooks → Before User Created →
-- Postgres function: private.hook_before_user_created.
-- Válasz: {} = engedély, {"error": {...}} = a fiók létre sem jön.
-- ---------------------------------------------------------------------------
create function private.hook_before_user_created(event jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  u jsonb := event -> 'user';
begin
  -- Névtelen fiók: a gyerek mód eszközfiókja (3. fázis). Párosítás nélkül semmihez
  -- nincs joga; a névtelen belépés a 3. fázisig ki is van kapcsolva.
  if coalesce((u ->> 'is_anonymous')::boolean, false) then
    return '{}'::jsonb;
  end if;

  if exists (select 1 from private.allowed_emails a where a.email = lower(u ->> 'email')) then
    return '{}'::jsonb;
  end if;

  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'Ez a cím nincs engedélyezve.'
  ));
end
$$;

revoke all on function private.hook_before_user_created(jsonb) from public, anon, authenticated;
grant execute on function private.hook_before_user_created(jsonb) to supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- Allowlist, 2. réteg és profil: trigger az auth.users táblán. Akkor is véd, ha
-- a hook nincs bekötve (pl. dashboardon kézzel felvett felhasználó).
-- ---------------------------------------------------------------------------
create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  a    private.allowed_emails;
  name text;
begin
  if new.is_anonymous then
    return new;  -- eszközfiók: nincs profil, nincs háztartás-tagság
  end if;

  select * into a from private.allowed_emails where email = lower(new.email);
  if not found then
    raise exception 'Ez a cím nincs engedélyezve.' using errcode = '42501';
  end if;

  name := left(btrim(coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    split_part(new.email, '@', 1)
  )), 40);

  insert into public.profiles (id, display_name, app_role)
  values (new.id, name, a.app_role);

  if a.household_id is not null then
    insert into public.household_members (household_id, user_id, role)
    values (a.household_id, new.id, a.household_role);
  end if;

  return new;
end
$$;

revoke all on function private.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();
