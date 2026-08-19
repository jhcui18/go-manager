-- 014: usernames are Instagram handles, which are lowercase-only — store them
-- that way. Columns are already citext (comparisons were fine); the problem was
-- mixed-case stored VALUES splitting one joiner in two wherever code groups by
-- raw text (JS object keys, group by ::text). A trigger normalizes every future
-- write regardless of path (RPCs, admin table writes); the backfill fixes the
-- rows already in place. Lowercasing can't collide under citext uniqueness,
-- since equal-under-citext values stay equal.
create or replace function lowercase_username()
returns trigger language plpgsql as $$
begin
  new.username := lower(trim(new.username));
  return new;
end $$;

drop trigger if exists lowercase_username on claims;
create trigger lowercase_username before insert or update of username on claims
  for each row execute function lowercase_username();
drop trigger if exists lowercase_username on payments;
create trigger lowercase_username before insert or update of username on payments
  for each row execute function lowercase_username();
drop trigger if exists lowercase_username on shipping_requests;
create trigger lowercase_username before insert or update of username on shipping_requests
  for each row execute function lowercase_username();
drop trigger if exists lowercase_username on shop_orders;
create trigger lowercase_username before insert or update of username on shop_orders
  for each row execute function lowercase_username();
drop trigger if exists lowercase_username on gc_members;
create trigger lowercase_username before insert or update of username on gc_members
  for each row execute function lowercase_username();

update claims set username = lower(username::text) where username::text <> lower(username::text);
update payments set username = lower(username::text) where username::text <> lower(username::text);
update shipping_requests set username = lower(username::text) where username::text <> lower(username::text);
update shop_orders set username = lower(username::text) where username::text <> lower(username::text);
update gc_members set username = lower(username::text) where username::text <> lower(username::text);
