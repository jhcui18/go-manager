-- 035: a claim stays flagged Paid only while the joiner's confirmed payments on
-- that GO cover every unit flagged Paid. Found 2026-09-22: Nagoya Day2 went
-- from $12 to $14 after joiners had paid $12, leaving ten SUIATSU cards
-- flagged Paid though $2 short each (Owed was right — it is ledger-based — but
-- the label lied). Any price rise (POB price / OT price / a claim's override)
-- now re-checks the affected joiners and un-flags their newest Paid units on
-- that POB until the ledger covers what remains flagged. The one-off backfill
-- below applies the same rule GO-wide to rows already in that state.
-- Unit pricing mirrors apply_balance (022): set-shaped slots flat, OT set =
-- max(override) else ot_price, everything else price × qty.

create or replace function unflag_uncovered_paid(p_go_id uuid, p_sub_item_id uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_user citext; v_short numeric; v_unit record; n int := 0;
begin
  for v_user in
    select distinct c.username from claims c join sub_items si on si.id = c.sub_item_id
     where si.go_id = p_go_id and c.status = 'secured' and c.payment_status = 'paid'
       and (p_sub_item_id is null or c.sub_item_id = p_sub_item_id)
  loop
    -- flagged-paid value on this GO minus confirmed payments on this GO
    with sec as (
      select c.id, c.set_id, c.is_ot, c.qty, c.price_override, c.created_at, si.price, si.ot_price, si.id as si_id,
             (c.member_id is not null and c.set_id is not null and si.order_mode = 'set'
              and exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                    or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                    or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) as set_shaped
        from claims c join sub_items si on si.id = c.sub_item_id
       where si.go_id = p_go_id and c.username = v_user and c.status = 'secured' and c.payment_status = 'paid'
    ), units as (
      select case when set_shaped then coalesce(price_override, price) else coalesce(price_override, price) * qty end as value
        from sec where not (is_ot and set_shaped)
      union all
      select coalesce(max(price_override), max(ot_price)) from sec where is_ot and set_shaped group by set_id
    )
    select coalesce(sum(value), 0)
         - coalesce((select sum(amount) from payments where username = v_user and go_id = p_go_id and is_shop = false and status = 'confirmed'), 0)
      into v_short from units;
    if v_short <= 0.005 then continue; end if;

    -- un-flag this joiner's Paid units on the changed POB (or any POB), newest first, until covered
    for v_unit in
      with sec as (
        select c.id, c.set_id, c.is_ot, c.qty, c.price_override, c.created_at, si.price, si.ot_price,
               (c.member_id is not null and c.set_id is not null and si.order_mode = 'set'
                and exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                      or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                      or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) as set_shaped
          from claims c join sub_items si on si.id = c.sub_item_id
         where si.go_id = p_go_id and c.username = v_user and c.status = 'secured' and c.payment_status = 'paid'
           and (p_sub_item_id is null or c.sub_item_id = p_sub_item_id)
      )
      select value, ids, created from (
        select case when set_shaped then coalesce(price_override, price) else coalesce(price_override, price) * qty end as value,
               array[id] as ids, created_at as created from sec where not (is_ot and set_shaped)
        union all
        select coalesce(max(price_override), max(ot_price)), array_agg(id), max(created_at) from sec where is_ot and set_shaped group by set_id
      ) u order by created desc
    loop
      exit when v_short <= 0.005;
      update claims set payment_status = 'unpaid' where id = any(v_unit.ids);
      n := n + 1;
      v_short := v_short - v_unit.value;
    end loop;
  end loop;
  return n;
end $$;

-- Price rise on a POB → re-check that POB's paid claims.
create or replace function unflag_after_price_rise() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  if new.price > old.price or new.ot_price > old.ot_price then perform unflag_uncovered_paid(new.go_id, new.id); end if;
  return null;
end $$;
drop trigger if exists unflag_on_price_rise on sub_items;
create trigger unflag_on_price_rise after update of price, ot_price on sub_items
  for each row execute function unflag_after_price_rise();

-- Override raised on a claim → re-check that POB's paid claims.
create or replace function unflag_after_override_rise() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_go uuid;
begin
  if pg_trigger_depth() > 1 then return null; end if;
  if new.price_override is not null and (old.price_override is null or new.price_override > old.price_override) then
    select go_id into v_go from sub_items where id = new.sub_item_id;
    perform unflag_uncovered_paid(v_go, new.sub_item_id);
  end if;
  return null;
end $$;
drop trigger if exists unflag_on_override_rise on claims;
create trigger unflag_on_override_rise after update of price_override on claims
  for each row execute function unflag_after_override_rise();

revoke execute on function unflag_uncovered_paid(uuid, uuid) from public, anon;
grant execute on function unflag_uncovered_paid(uuid, uuid) to authenticated;
