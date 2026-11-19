-- Társasház: a régi adatok betöltése és a teljes kiürítés kikerül (nincs rájuk szükség);
-- helyettük a létszám egy bejegyzése törölhető.

drop function if exists public.th_import(jsonb);
drop function if exists public.th_reset(text, boolean);

-- A létszám egy bejegyzésének törlése (egy adott naptól érvényes beállítás), csak a kezelőnek.
create function public.th_delete_residents(p_valid_from date) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.th_require_manager();
  delete from public.th_residents where valid_from = p_valid_from;
end $$;

revoke all on function public.th_delete_residents(date) from public, anon;
grant execute on function public.th_delete_residents(date) to authenticated;
