-- Enable RLS everywhere.
alter table gos enable row level security;
alter table sub_items enable row level security;
alter table members enable row level security;
alter table versions enable row level security;
alter table sets enable row level security;
alter table claims enable row level security;
alter table payments enable row level security;
alter table gc_members enable row level security;
alter table shipping_requests enable row level security;
alter table shipping_request_items enable row level security;
alter table listings enable row level security;
alter table listing_variants enable row level security;
alter table shop_orders enable row level security;
alter table store_orders enable row level security;

-- Admin (single authenticated user): full CRUD on everything.
do $$
declare t text;
begin
  foreach t in array array['gos','sub_items','members','versions','sets','claims',
    'payments','gc_members','shipping_requests','shipping_request_items',
    'listings','listing_variants','shop_orders','store_orders']
  loop
    execute format('create policy admin_all on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- Anon: read-only, and only on non-address tables (deviation 5 adds payments,
-- shop_orders, shipping_request_items for the My Orders page).
do $$
declare t text;
begin
  foreach t in array array['gos','sub_items','members','versions','sets','claims',
    'listings','listing_variants','payments','shop_orders','shipping_request_items']
  loop
    execute format('create policy anon_read on %I for select to anon using (true)', t);
  end loop;
end $$;
-- No anon policy on shipping_requests, gc_members, store_orders → invisible to anon.
-- No anon insert/update/delete policies anywhere → all anon writes go through RPCs.

-- Shipping status WITHOUT addresses (closes the open-addresses hole).
-- security_invoker = false (default): the view runs as its owner (postgres),
-- bypassing shipping_requests RLS but exposing only these columns.
create view shipping_status as
  select id, username, ems_fee, dom_fee, total_fee, shipped, created_at
  from shipping_requests;
grant select on shipping_status to anon, authenticated;
