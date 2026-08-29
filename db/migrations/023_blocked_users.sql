-- 023: blocklist backing the Rules blocking policy. Blocked joiners cannot make
-- NEW commitments (claims, shop orders) — enforced by a before-insert trigger so
-- every write path is covered — but can still pay what they owe and request
-- shipment of paid items (payments/shipping deliberately unguarded). The table
-- is admin-only; anon can't read who is blocked.
create table if not exists blocked_users (
  username citext primary key,
  reason text,
  created_at timestamptz not null default now()
);
alter table blocked_users enable row level security;
create policy "admin all" on blocked_users for all to authenticated using (true) with check (true);
grant select, insert, update, delete on blocked_users to authenticated;

create or replace function reject_blocked_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from blocked_users b where b.username = new.username) then
    raise exception 'blocked';
  end if;
  return new;
end $$;

drop trigger if exists reject_blocked on claims;
create trigger reject_blocked before insert on claims
  for each row execute function reject_blocked_user();
drop trigger if exists reject_blocked on shop_orders;
create trigger reject_blocked before insert on shop_orders
  for each row execute function reject_blocked_user();
