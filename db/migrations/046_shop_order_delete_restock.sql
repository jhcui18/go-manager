-- 046: deleting a shop order returns its quantity to the listing (or variant).
-- place_shop_order subtracts stock on insert, but nothing gave it back on delete:
-- the admin page only bumped the number on screen, so every deleted order left
-- the listing short after a reload. Shipped orders don't restock — that stock
-- is gone.
create or replace function shop_order_restock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.fulfillment = 'Shipped' then return old; end if;
  if old.variant_id is not null then
    update listing_variants set qty = qty + coalesce(old.qty, 0) where id = old.variant_id;
  else
    update listings set qty = qty + coalesce(old.qty, 0) where id = old.listing_id;
  end if;
  return old;
end $$;

drop trigger if exists shop_order_restock on shop_orders;
create trigger shop_order_restock after delete on shop_orders
  for each row execute function shop_order_restock();
