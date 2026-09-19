-- 032: usernames never carry a leading "@". submit_claim strips ONE leading @,
-- so a joiner who typed "@@handle" (browser autofill of "@handle" + a typed @)
-- landed as "@handle" — a second identity invisible to My orders (48 of one
-- joiner's claims, 2026-08-27..09-16, found 2026-09-19). The write trigger from
-- 014 now strips every leading @ and whitespace on every path, and the backfill
-- merges any rows already stored that way.
create or replace function lowercase_username()
returns trigger language plpgsql as $$
begin
  new.username := lower(regexp_replace(trim(new.username), '^[@\s]+', ''));
  return new;
end $$;

update claims            set username = regexp_replace(username::text, '^[@\s]+', '') where username::text ~ '^[@\s]';
update payments          set username = regexp_replace(username::text, '^[@\s]+', '') where username::text ~ '^[@\s]';
update shipping_requests set username = regexp_replace(username::text, '^[@\s]+', '') where username::text ~ '^[@\s]';
update shop_orders       set username = regexp_replace(username::text, '^[@\s]+', '') where username::text ~ '^[@\s]';
update gc_members        set username = regexp_replace(username::text, '^[@\s]+', '') where username::text ~ '^[@\s]';
