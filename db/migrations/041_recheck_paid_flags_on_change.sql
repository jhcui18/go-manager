-- 041: Paid flags are re-checked automatically, not only on a price rise.
--
-- 035 un-flagged uncovered Paid units when a POB's price went up. Two other ways
-- to strand a Paid flag were left open, and both were hit in practice:
--   * a claim LEAVES 'secured' (set un-secured, claim set back to pending) —
--     anasoff.sanchez's Nagoya Day2 OT8 stayed Paid while pending with no money
--     behind it (2026-10-09);
--   * confirmed money is taken back — a payment un-confirmed or rejected, its
--     amount lowered, a confirmed row deleted, or a negative Refund row added
--     (cinamonjules, 2026-10-06, fixed by hand).
--
-- The invariant is the same in every case: a claim stays flagged Paid only while
-- the joiner's confirmed payments on that GO cover every unit still flagged Paid.
-- recheck_paid_flags() enforces it for one joiner on one GO; triggers call it
-- whenever the ledger could have moved against them. Deliberate admin flagging
-- (clicking the Paid badge) is NOT re-checked — only status and money changes are.
--
-- Body of the per-user logic is lifted unchanged from 035's unflag_uncovered_paid,
-- which is rewritten below as a loop over that function so existing callers and
-- the 035 price triggers keep working.

create or replace function recheck_paid_flags(p_username citext, p_go_id uuid, p_sub_item_id uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_short numeric; v_unit record; n int := 0;
begin
  if p_username is null or p_go_id is null then return 0; end if;
  -- flagged-paid value on this GO minus confirmed payments on this GO
  with sec as (
    select c.id, c.set_id, c.is_ot, c.qty, c.price_override, c.created_at, si.price, si.ot_price,
           (c.member_id is not null and c.set_id is not null and si.order_mode = 'set'
            and exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                  or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                  or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) as set_shaped
      from claims c join sub_items si on si.id = c.sub_item_id
     where si.go_id = p_go_id and c.username = p_username and c.status = 'secured' and c.payment_status = 'paid'
  ), units as (
    select case when set_shaped then coalesce(price_override, price) else coalesce(price_override, price) * qty end as value
      from sec where not (is_ot and set_shaped)
    union all
    select coalesce(max(price_override), max(ot_price)) from sec where is_ot and set_shaped group by set_id
  )
  select coalesce(sum(value), 0)
       - coalesce((select sum(amount) from payments where username = p_username and go_id = p_go_id and is_shop = false and status = 'confirmed'), 0)
    into v_short from units;
  if v_short <= 0.005 then return 0; end if;

  -- un-flag this joiner's Paid units (on the named POB, or any POB), newest first, until covered
  for v_unit in
    with sec as (
      select c.id, c.set_id, c.is_ot, c.qty, c.price_override, c.created_at, si.price, si.ot_price,
             (c.member_id is not null and c.set_id is not null and si.order_mode = 'set'
              and exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                    or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                    or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) as set_shaped
        from claims c join sub_items si on si.id = c.sub_item_id
       where si.go_id = p_go_id and c.username = p_username and c.status = 'secured' and c.payment_status = 'paid'
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
  return n;
end $$;

-- GO-wide sweep, unchanged behaviour: every joiner with Paid units on the GO.
create or replace function unflag_uncovered_paid(p_go_id uuid, p_sub_item_id uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_user citext; n int := 0;
begin
  for v_user in
    select distinct c.username from claims c join sub_items si on si.id = c.sub_item_id
     where si.go_id = p_go_id and c.status = 'secured' and c.payment_status = 'paid'
       and (p_sub_item_id is null or c.sub_item_id = p_sub_item_id)
  loop
    n := n + recheck_paid_flags(v_user, p_go_id, p_sub_item_id);
  end loop;
  return n;
end $$;

-- A claim leaving 'secured' (un-secured, set back to pending, dropped) re-checks
-- that joiner's flags on that GO.
create or replace function recheck_after_unsecure() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_go uuid;
begin
  if pg_trigger_depth() > 1 then return null; end if;
  if old.status = 'secured' and new.status is distinct from 'secured' then
    select go_id into v_go from sub_items where id = new.sub_item_id;
    if v_go is not null then perform recheck_paid_flags(new.username, v_go); end if;
  end if;
  return null;
end $$;
drop trigger if exists recheck_on_unsecure on claims;
create trigger recheck_on_unsecure after update of status on claims
  for each row execute function recheck_after_unsecure();

-- Confirmed money taken back (un-confirmed, rejected, amount lowered, row deleted,
-- or a negative Refund row added) re-checks that joiner's flags on that GO.
create or replace function recheck_after_payment_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_user citext; v_go uuid; v_drop boolean := false;
begin
  if pg_trigger_depth() > 1 then return null; end if;
  if tg_op = 'DELETE' then
    v_user := old.username; v_go := old.go_id;
    v_drop := old.status = 'confirmed' and old.amount > 0;
  elsif tg_op = 'INSERT' then
    v_user := new.username; v_go := new.go_id;
    v_drop := new.status = 'confirmed' and new.amount < 0;
  else
    v_user := new.username; v_go := new.go_id;
    v_drop := old.status = 'confirmed'
              and (new.status is distinct from 'confirmed' or new.amount < old.amount);
  end if;
  if v_drop and v_go is not null then perform recheck_paid_flags(v_user, v_go); end if;
  return null;
end $$;
drop trigger if exists recheck_on_payment_change on payments;
create trigger recheck_on_payment_change after insert or delete or update of status, amount on payments
  for each row execute function recheck_after_payment_change();

revoke execute on function recheck_paid_flags(citext, uuid, uuid) from public, anon;
grant execute on function recheck_paid_flags(citext, uuid, uuid) to authenticated;
