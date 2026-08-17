-- 010: link shipping request items to the claims/shop orders they bundle.
-- The Sheets backend stored these links; the Supabase port kept only text labels,
-- so after a reload the app couldn't hide already-requested items in My orders or
-- flip the bundled items' fulfillment when a request was marked shipped.
alter table shipping_request_items
  add column if not exists claim_id uuid references claims(id) on delete set null,
  add column if not exists shop_order_id uuid references shop_orders(id) on delete set null;

create or replace function submit_shipping(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; it jsonb;
begin
  insert into shipping_requests (username, full_name, address1, address2, city,
                                 state, postal, country, notes, email)
  values (regexp_replace(trim(p->>'username'), '^@', ''),
          p->>'full_name', p->>'address1', nullif(p->>'address2',''),
          p->>'city', p->>'state', p->>'postal', p->>'country',
          nullif(p->>'notes',''), nullif(p->>'email',''))
  returning id into v_id;
  for it in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    insert into shipping_request_items (request_id, go_id, description, qty, claim_id, shop_order_id)
    values (v_id, nullif(it->>'go_id','')::uuid, it->>'description',
            greatest(coalesce((it->>'qty')::int,1),1),
            nullif(it->>'claim_id','')::uuid, nullif(it->>'shop_order_id','')::uuid);
  end loop;
  return jsonb_build_object('ok', true, 'request_id', v_id);
end $$;

-- shipping_status: also expose which items each request bundles (type/id/label) so
-- My orders keeps hiding already-requested items after a reload. Claim/shop-order
-- ids are already anon-visible via the boards; addresses stay hidden as before.
create or replace view shipping_status as
  select r.id, r.username, r.ems_fee, r.dom_fee, r.total_fee, r.shipped, r.created_at,
         (select coalesce(jsonb_agg(jsonb_build_object(
             'type', case when i.claim_id is not null then 'claim'
                          when i.shop_order_id is not null then 'shop'
                          else 'item' end,
             'id', coalesce(i.claim_id::text, i.shop_order_id::text, i.id::text),
             'label', i.description) order by i.id), '[]'::jsonb)
            from shipping_request_items i where i.request_id = r.id) as items
  from shipping_requests r;
