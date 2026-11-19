-- Társasház: lezárás egyedi utalásokkal.
--
-- Régi, már rendezett időszaknál az utalások a valóban megtörtént utalások lehetnek, amelyek
-- kerekítés miatt néhány forinttal eltérhetnek a számított egyenlegtől. Ezért:
--   * p_tolerance: lakásonként ennyi Ft eltérés megengedett (0–10, alapból 0);
--   * p_paid: az utalások azonnal beérkezettként kerülnek be (az időszak rögtön „rendezve”).
-- Az eltérés nem tárolódik külön: a kliens a tételekből és az utalásokból látja.

drop function public.th_close_period(uuid, jsonb);

create function public.th_close_period(p_id uuid, p_transfers jsonb, p_tolerance integer default 0, p_paid boolean default false)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare f text; bal integer; net integer; tol integer := least(greatest(coalesce(p_tolerance, 0), 0), 10); t jsonb;
begin
  perform private.th_require_manager();
  perform private.th_require_open(p_id);
  for t in select * from jsonb_array_elements(coalesce(p_transfers, '[]')) loop
    if (t ->> 'from') not in ('fsz-1', 'fsz-2', 'em-3', 'em-4') or (t ->> 'to') not in ('fsz-1', 'fsz-2', 'em-3', 'em-4')
       or t ->> 'from' = t ->> 'to' or (t ->> 'amount')::integer <= 0 then
      raise exception 'Hibás utalás: % → %, % Ft.', t ->> 'from', t ->> 'to', t ->> 'amount' using errcode = '22023';
    end if;
  end loop;
  for f in select code from public.th_flats loop
    select coalesce(sum(i.amount) filter (where i.paid_by = f), 0)
         - coalesce((select sum(s.amount) from public.th_item_shares s join public.th_items i2 on i2.id = s.item_id
                     where i2.period_id = p_id and s.flat = f), 0)
      into bal from public.th_items i where i.period_id = p_id;
    select coalesce(sum((x ->> 'amount')::integer) filter (where x ->> 'to' = f), 0)
         - coalesce(sum((x ->> 'amount')::integer) filter (where x ->> 'from' = f), 0)
      into net from jsonb_array_elements(coalesce(p_transfers, '[]')) x;
    if abs(bal - net) > tol then
      raise exception 'Az utalások nem adják ki a(z) % egyenlegét (eltérés: % Ft).', f, net - bal using errcode = '22023';
    end if;
  end loop;
  insert into public.th_transfers (period_id, from_flat, to_flat, amount, paid_at)
  select p_id, x ->> 'from', x ->> 'to', (x ->> 'amount')::integer, case when p_paid then now() end
  from jsonb_array_elements(coalesce(p_transfers, '[]')) x;
  update public.th_periods set status = 'closed', closed_at = now(),
    ends_on = coalesce(ends_on, current_date) where id = p_id;
end $$;

revoke all on function public.th_close_period(uuid, jsonb, integer, boolean) from public, anon;
grant execute on function public.th_close_period(uuid, jsonb, integer, boolean) to authenticated;
