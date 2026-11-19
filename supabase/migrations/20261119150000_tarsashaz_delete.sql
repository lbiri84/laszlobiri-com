-- Társasház: időszak törlése és az elszámoló kiürítése (csak a kezelő).
--
-- th_delete_period: egy időszak a tételeivel, lakásrészeivel és utalásaival. Ha már volt
--   beérkezett utalás, csak p_force = true-val.
-- th_reset: minden időszak és vízóra-leolvasás; p_settings = true esetén a tulajdoni
--   hányad és a lakók száma is. Véletlen hívás ellen a p_confirm = 'TÖRLÉS' kell.
-- A hozzáférések (lakás, kezelő) nem változnak.

create function public.th_delete_period(p_id uuid, p_force boolean default false) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare paid integer;
begin
  perform private.th_require_manager();
  if not exists (select 1 from public.th_periods where id = p_id) then
    raise exception 'Nincs ilyen időszak.' using errcode = '22023';
  end if;
  select count(*) into paid from public.th_transfers where period_id = p_id and paid_at is not null;
  if paid > 0 and not coalesce(p_force, false) then
    raise exception 'Ebben az időszakban már % utalás megérkezett.', paid using errcode = '22023';
  end if;
  delete from public.th_periods where id = p_id;
end $$;

create function public.th_reset(p_confirm text, p_settings boolean default false) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.th_require_manager();
  if p_confirm is distinct from 'TÖRLÉS' then
    raise exception 'A törléshez írd be: TÖRLÉS' using errcode = '22023';
  end if;
  delete from public.th_periods where true;
  delete from public.th_readings where true;
  if coalesce(p_settings, false) then
    delete from public.th_residents where true;
    delete from public.th_flats where true;
  end if;
end $$;

revoke all on function public.th_delete_period(uuid, boolean), public.th_reset(text, boolean) from public, anon;
grant execute on function public.th_delete_period(uuid, boolean), public.th_reset(text, boolean) to authenticated;
