-- 042: per-buyer cap on a shop listing. listings.max_per_user (null = no limit)
-- counts UNITS a buyer already holds: per VARIANT on a listing that has variants
-- (so 2 means 2 of each version), per listing otherwise. Enforced inside
-- place_shop_order under the same row lock that guards stock, so two open tabs
-- cannot beat it. Lowering a cap never removes orders already placed; it only
-- refuses new ones. Body otherwise as 037.
alter table listings add column if not exists max_per_user int check (max_per_user is null or max_per_user > 0);

create or replace function place_shop_order(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_listing listings%rowtype;
  v_variant listing_variants%rowtype;
  v_qty int := greatest(coalesce((p->>'qty')::int,1),1);
  v_user citext;
  v_have int;
  v_id uuid;
begin
  select * into v_listing from listings
   where id = (p->>'listing_id')::uuid for update;
  if not found or v_listing.status <> 'active' then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  v_user := lower(regexp_replace(trim(p->>'username'), '^[@\s]+', ''));
  if coalesce(p->>'variant_id','') <> '' then
    select * into v_variant from listing_variants
     where id = (p->>'variant_id')::uuid and listing_id = v_listing.id for update;
    if not found or v_variant.qty < v_qty then
      return jsonb_build_object('ok', false, 'error', 'stock');
    end if;
  else
    if coalesce(v_listing.qty, 0) < v_qty then
      return jsonb_build_object('ok', false, 'error', 'stock');
    end if;
  end if;

  if v_listing.max_per_user is not null then
    select coalesce(sum(o.qty), 0) into v_have from shop_orders o
     where o.listing_id = v_listing.id and o.username = v_user
       and (v_variant.id is null or o.variant_id = v_variant.id);
    if v_have + v_qty > v_listing.max_per_user then
      return jsonb_build_object('ok', false, 'error', 'limit',
        'max_per_user', v_listing.max_per_user, 'already', v_have,
        'variant', v_variant.name,
        'message', 'Limit ' || v_listing.max_per_user || ' per person'
                   || case when v_variant.name is not null then ' for ' || v_variant.name else '' end
                   || case when v_have > 0 then ' — you already have ' || v_have || '.' else '.' end);
    end if;
  end if;

  if v_variant.id is not null then
    update listing_variants set qty = qty - v_qty where id = v_variant.id;
  else
    update listings set qty = qty - v_qty where id = v_listing.id;
  end if;
  insert into shop_orders (listing_id, variant_id, username, email, qty,
                           unit_price, payment_status, fulfillment)
  values (v_listing.id, v_variant.id, v_user,
          nullif(p->>'email',''), v_qty, v_listing.price, 'unpaid', 'Pending')
  returning id into v_id;
  return jsonb_build_object('ok', true, 'order_id', v_id);
end $$;
