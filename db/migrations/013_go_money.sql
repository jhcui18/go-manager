-- 013: per-GO expected-collection total for the admin Active GOs list, mirroring
-- the frontend's paymentOwedUnits pricing exactly: secured claims only; set-based
-- OT full sets price ONCE per (sub_item, user, set) at ot_price; every other
-- secured claim (incl. batch OT rows) prices at sub_item price x qty.
create or replace view go_money
with (security_invoker = on) as
with sec as (
  select si.go_id, si.id as si_id, si.order_mode,
         coalesce(si.price, 0) as price, coalesce(si.ot_price, 0) as ot_price,
         c.username, c.set_id, c.is_ot, coalesce(c.qty, 1) as qty
  from claims c join sub_items si on si.id = c.sub_item_id
  where c.status = 'secured'
),
per_card as (
  select go_id, sum(qty * price) as amt
  from sec
  where not (is_ot and order_mode = 'set')
  group by go_id
),
ot_groups as (
  select go_id, si_id, username, set_id, max(ot_price) as ot_price
  from sec
  where is_ot and order_mode = 'set'
  group by go_id, si_id, username, set_id
),
ot_amt as (
  select go_id, sum(ot_price) as amt from ot_groups group by go_id
)
select g.id as go_id,
       coalesce(pc.amt, 0) + coalesce(oa.amt, 0) as expected
from gos g
left join per_card pc on pc.go_id = g.id
left join ot_amt oa on oa.go_id = g.id;

revoke all on go_money from public, anon;
grant select on go_money to authenticated;
