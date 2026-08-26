-- 019: shipping_status items carry per-item prices so joiners see the same
-- receipt the admin does. Pricing matches the admin queue (018 rule):
-- claim links price at coalesce(price_override, item price) — OT-set cards
-- price as null (the set is one unit) — shop links at unit_price * qty;
-- legacy unlinked lines stay unpriced.
create or replace view shipping_status as
  select r.id, r.username, r.ems_fee, r.dom_fee, r.total_fee, r.shipped, r.created_at,
         (select coalesce(jsonb_agg(jsonb_build_object(
             'type', case when i.claim_id is not null then 'claim'
                          when i.shop_order_id is not null then 'shop'
                          else 'item' end,
             'id', coalesce(i.claim_id::text, i.shop_order_id::text, i.id::text),
             'label', i.description,
             'ot', coalesce(c.is_ot, false),
             'price', case when i.claim_id is not null and not coalesce(c.is_ot, false)
                             then coalesce(c.price_override, si.price)
                           when i.shop_order_id is not null
                             then so.unit_price * so.qty
                           else null end) order by i.id), '[]'::jsonb)
            from shipping_request_items i
            left join claims c on c.id = i.claim_id
            left join sub_items si on si.id = c.sub_item_id
            left join shop_orders so on so.id = i.shop_order_id
            where i.request_id = r.id) as items,
         r.method, r.tracking_number
  from shipping_requests r;
