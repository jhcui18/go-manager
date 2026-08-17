-- 011: shipping method (stamped/tracked) chosen by the joiner + tracking number
-- entered by the admin. Buyers see both via shipping_status; the tracking number
-- renders as a universal 17TRACK link (carrier auto-detected, no carrier column).
alter table shipping_requests
  add column if not exists method text not null default 'tracked'
    check (method in ('stamped','tracked')),
  add column if not exists tracking_number text;

create or replace function submit_shipping(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; it jsonb;
begin
  insert into shipping_requests (username, full_name, address1, address2, city,
                                 state, postal, country, notes, email, method)
  values (regexp_replace(trim(p->>'username'), '^@', ''),
          p->>'full_name', p->>'address1', nullif(p->>'address2',''),
          p->>'city', p->>'state', p->>'postal', p->>'country',
          nullif(p->>'notes',''), nullif(p->>'email',''),
          case when p->>'method' = 'stamped' then 'stamped' else 'tracked' end)
  returning id into v_id;
  for it in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    insert into shipping_request_items (request_id, go_id, description, qty, claim_id, shop_order_id)
    values (v_id, nullif(it->>'go_id','')::uuid, it->>'description',
            greatest(coalesce((it->>'qty')::int,1),1),
            nullif(it->>'claim_id','')::uuid, nullif(it->>'shop_order_id','')::uuid);
  end loop;
  return jsonb_build_object('ok', true, 'request_id', v_id);
end $$;

create or replace view shipping_status as
  select r.id, r.username, r.ems_fee, r.dom_fee, r.total_fee, r.shipped, r.created_at,
         (select coalesce(jsonb_agg(jsonb_build_object(
             'type', case when i.claim_id is not null then 'claim'
                          when i.shop_order_id is not null then 'shop'
                          else 'item' end,
             'id', coalesce(i.claim_id::text, i.shop_order_id::text, i.id::text),
             'label', i.description) order by i.id), '[]'::jsonb)
            from shipping_request_items i where i.request_id = r.id) as items,
         r.method, r.tracking_number
  from shipping_requests r;
