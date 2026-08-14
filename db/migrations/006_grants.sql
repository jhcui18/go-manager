-- Fix: 002_rls.sql created RLS policies but never granted the underlying
-- table-level privileges. In Postgres, RLS policies only take effect once a
-- role already holds the table-level GRANT; without it, PostgREST returns
-- 42501 "permission denied for table X" for every request regardless of
-- policy, which made anon_read policies dead code (discovered while writing
-- db/test_rls.sh: anon reads that should 200 were 401ing outright).

-- Anon: SELECT only, matching the anon_read policy list in 002_rls.sql.
grant select on gos, sub_items, members, versions, sets, claims,
  listings, listing_variants, payments, shop_orders, shipping_request_items
  to anon;

-- Authenticated (admin): full CRUD, matching the admin_all policy's FOR ALL
-- scope in 002_rls.sql.
grant select, insert, update, delete on
  gos, sub_items, members, versions, sets, claims, payments, gc_members,
  shipping_requests, shipping_request_items, listings, listing_variants,
  shop_orders, store_orders
  to authenticated;
