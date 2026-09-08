-- 029: hole-free member columns, guaranteed at the database. Compaction used to
-- depend on each frontend path remembering to call compactMemberColumn — the
-- board's x did, the edit modal's Remove didn't (fixed 09-06), the modal's
-- member REASSIGNMENT never did, and stale browser tabs bypass any client fix.
-- Now any claim DELETE or member change on a set-shaped item repacks that
-- member's column server-side: non-OT claims slide down into the lowest set
-- positions not blocked by an OT claim, in order. Deliberate set moves
-- (set_id changes) do NOT repack — those are intentional placements.
create or replace function repack_member_column(p_sub_item uuid, p_member uuid)
returns void language plpgsql security definer set search_path = public as $$
declare mv record;
begin
  if p_sub_item is null or p_member is null then return; end if;
  if not exists (select 1 from sub_items where id = p_sub_item and order_mode = 'set') then return; end if;
  -- Same lock submit_claim takes, so repacks never race slot assignment.
  perform pg_advisory_xact_lock(hashtextextended(p_sub_item::text, 0));
  for mv in
    with cl as (
      select c.id, s.set_no, row_number() over (order by s.set_no) as rn
      from claims c join sets s on s.id = c.set_id
      where c.sub_item_id = p_sub_item and c.member_id = p_member and not c.is_ot
    ),
    avail as (
      select s.set_no, s.id as set_id, row_number() over (order by s.set_no) as rn
      from sets s
      where s.sub_item_id = p_sub_item
        and not exists (select 1 from claims c2
                         where c2.set_id = s.id and c2.member_id = p_member and c2.is_ot)
    )
    select cl.id as claim_id, a.set_id as new_set_id
    from cl join avail a on a.rn = cl.rn
    where a.set_no < cl.set_no
    order by a.set_no
  loop
    update claims set set_id = mv.new_set_id where id = mv.claim_id;
  end loop;
end $$;

create or replace function repack_after_claim_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  perform repack_member_column(old.sub_item_id, old.member_id);
  return null;
end $$;

drop trigger if exists repack_on_delete on claims;
create trigger repack_on_delete after delete on claims
  for each row when (old.set_id is not null and old.member_id is not null)
  execute function repack_after_claim_change();
drop trigger if exists repack_on_member_change on claims;
create trigger repack_on_member_change after update of member_id on claims
  for each row when (old.member_id is distinct from new.member_id and old.set_id is not null)
  execute function repack_after_claim_change();
