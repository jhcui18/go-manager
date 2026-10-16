-- 044: per-GO count of secured joiners not yet marked "added to group chat".
--
-- The admin GOs tab shows "N not in GC" on each card and keeps a closed GO
-- unfolded while that count is above zero. Claims load per GO on demand, so
-- the list cannot derive this from goJoiners(); this view is one small row
-- per GO instead. Same access model as go_claim_activity (009): admin only.
--
-- Applied via execute_sql on 2026-10-15 (apply_migration was rejecting
-- bodies); the history table has no row for it.

create or replace view go_gc_pending with (security_invoker = on) as
select si.go_id,
       count(distinct c.username) as joiners,
       count(distinct c.username) filter (where g.username is null) as not_added
from claims c
join sub_items si on si.id = c.sub_item_id
left join gc_members g on g.go_id = si.go_id and lower(trim(g.username::text)) = lower(trim(c.username::text))
where c.status = 'secured'
group by si.go_id;

revoke all on go_gc_pending from public, anon;
grant select on go_gc_pending to authenticated;
