-- Post-review hardening: strip unusable-but-dangerous default privileges and
-- pin search_path on the remaining unpinned functions.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
alter function assert_admin() set search_path = public;
alter function set_updated_at() set search_path = public;
-- rls_auto_enable: dashboard-era event-trigger helper, not part of this app's
-- migrations. Drop it so fresh-project provisioning from db/migrations/ is complete.
drop function if exists public.rls_auto_enable() cascade;
