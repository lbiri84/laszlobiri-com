-- Takarítás: a társasházat csak az admin szerkeszti; a kivezetett funkciók maradékai kikerülnek.
--
--   * A kezelő mostantól csak az admin (app_role = 'admin', a társasház oldal jogával). A külön
--     kezelői jog (allowed_emails.th_manager) és az admin oldal „kezelő” pipája megszűnik.
--   * admin_access_list: a „Család” oszlop (in_household) és a th_manager kikerül.
--   * admin_set_flat: csak a lakás (p_manager nélkül).
--   * th_items.method: az „átvett” mód (a megszűnt régi adatbetöltésé) kikerül, ha nincs ilyen tétel.

create or replace function private.th_is_manager() returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_app('tarsashaz') and private.is_admin()
$$;

drop function public.admin_set_flat(text, text, boolean);
create function public.admin_set_flat(p_email text, p_flat text) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not private.is_admin() then
    raise exception 'Csak admin.' using errcode = '42501';
  end if;
  if p_flat is not null and p_flat not in ('fsz-1', 'fsz-2', 'em-3', 'em-4') then
    raise exception 'Ismeretlen lakás.' using errcode = '22023';
  end if;
  update private.allowed_emails set flat = p_flat, updated_at = now() where email = lower(btrim(p_email));
  if not found then raise exception 'Nincs ilyen cím.' using errcode = '22023'; end if;
end $$;
revoke all on function public.admin_set_flat(text, text) from public, anon;
grant execute on function public.admin_set_flat(text, text) to authenticated;

drop function public.admin_access_list();
create function public.admin_access_list()
returns table (
  email           text,
  apps            text[],
  app_role        text,
  note            text,
  display_name    text,
  has_account     boolean,
  last_sign_in_at timestamptz,
  added_at        timestamptz,
  flat            text
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then
    raise exception 'Csak admin.' using errcode = '42501';
  end if;
  return query
    select a.email, a.apps, a.app_role, a.note, p.display_name, u.id is not null, u.last_sign_in_at, a.created_at, a.flat
    from private.allowed_emails a
    left join auth.users u on lower(u.email) = a.email and not u.is_anonymous
    left join public.profiles p on p.id = u.id
    order by a.created_at, a.email;
end
$$;
revoke all on function public.admin_access_list() from public, anon;
grant execute on function public.admin_access_list() to authenticated;

alter table private.allowed_emails drop column th_manager;

do $$
begin
  if not exists (select 1 from public.th_items where method = 'atvett') then
    alter table public.th_items drop constraint th_items_method_check;
    alter table public.th_items add constraint th_items_method_check
      check (method in ('hanyad', 'letszam', 'viz', 'egyenlo', 'kezi'));
  else
    raise notice 'Van „átvett” tétel, a felosztási mód feltétele marad.';
  end if;
end $$;
