-- 037: a new shop order starts as Pending, not Ready. The column default and
-- place_shop_order both wrote 'Ready', so every order looked shippable the moment
-- it was placed (and a paid one showed up in Request shipping straight away).
-- Existing orders are left as they are. Body of place_shop_order as in 003,
-- with only the fulfillment literal changed.
alter table shop_orders alter column fulfillment set default 'Pending';

create or replace function place_shop_order(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_listing listings%rowtype;
  v_variant listing_variants%rowtype;
  v_qty int := greatest(coalesce((p->>'qty')::int,1),1);
  v_id uuid;
begin
  select * into v_listing from listings
   where id = (p->>'listing_id')::uuid for update;
  if not found or v_listing.status <> 'active' then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  if coalesce(p->>'variant_id','') <> '' then
    select * into v_variant from listing_variants
     where id = (p->>'variant_id')::uuid and listing_id = v_listing.id for update;
    if not found or v_variant.qty < v_qty then
      return jsonb_build_object('ok', false, 'error', 'stock');
    end if;
    update listing_variants set qty = qty - v_qty where id = v_variant.id;
  else
    if coalesce(v_listing.qty, 0) < v_qty then
      return jsonb_build_object('ok', false, 'error', 'stock');
    end if;
    update listings set qty = qty - v_qty where id = v_listing.id;
  end if;
  insert into shop_orders (listing_id, variant_id, username, email, qty,
                           unit_price, payment_status, fulfillment)
  values (v_listing.id, v_variant.id,
          regexp_replace(trim(p->>'username'), '^@', ''),
          nullif(p->>'email',''), v_qty, v_listing.price, 'unpaid', 'Pending')
  returning id into v_id;
  return jsonb_build_object('ok', true, 'order_id', v_id);
end $$;
