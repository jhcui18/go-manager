-- 009: "new claims" dot on admin GO cards.
-- gos.claims_seen_at = when the admin last opened that GO's Manage view;
-- defaults to migration time so existing GOs don't all light up at once.
alter table gos add column if not exists claims_seen_at timestamptz not null default now();

-- Latest claim time per GO (one tiny row per GO instead of pulling all claims).
-- security_invoker: runs under the caller's RLS; only authenticated is granted.
create or replace view go_claim_activity
with (security_invoker = on) as
  select si.go_id, max(c.created_at) as latest_claim_at
  from claims c
  join sub_items si on si.id = c.sub_item_id
  group by si.go_id;

revoke all on go_claim_activity from public, anon;
grant select on go_claim_activity to authenticated;
