-- 048: audit trail for joiner self-edits (047). Every edit_my_pending_claim call
-- writes one row per claim: who typed the handle, what changed, and the full
-- claim row before the change — so a claim a joiner removed (or a troll removed
-- under their handle) can be restored from the log. Admin-only table: RLS with
-- an authenticated policy and no anon grant, same as admin_notes (043).
create table if not exists claim_edit_log (
  id          uuid primary key default gen_random_uuid(),
  at          timestamptz not null default now(),
  username    citext not null,
  action      text not null,            -- delete | qty | member
  claim_id    uuid not null,
  sub_item_id uuid,
  go_id       uuid,
  item        text,                     -- "GO — sub-item" at the time of the edit
  detail      text,                     -- member/version name at the time
  after_detail text,                    -- member name after a member change
  before      jsonb not null,           -- full claims row before
  after       jsonb                     -- null for delete
);
create index if not exists claim_edit_log_at on claim_edit_log (at desc);
alter table claim_edit_log enable row level security;
drop policy if exists admin_all on claim_edit_log;
create policy admin_all on claim_edit_log for all to authenticated using (true) with check (true);
revoke all on claim_edit_log from anon;
grant select, delete on claim_edit_log to authenticated;

create or replace function edit_my_pending_claim(p_claim_ids uuid[], p_username citext,
                                                 p_action text, p_qty int default null,
                                                 p_member text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user citext := lower(regexp_replace(trim(p_username::text), '^@', ''));
        v_n int; v_claim claims%rowtype; v_member uuid; v_after claims%rowtype;
begin
  if p_claim_ids is null or cardinality(p_claim_ids) = 0 then
    raise exception 'No claims given';
  end if;
  select count(*) into v_n
    from claims c join sub_items si on si.id = c.sub_item_id join gos g on g.id = si.go_id
   where c.id = any(p_claim_ids) and c.username = v_user
     and c.status = 'pending' and c.payment_status = 'unpaid' and not c.archived
     and coalesce(c.fulfillment, 'Pending') = 'Pending'
     and not si.closed and g.status <> 'closed';
  if v_n <> cardinality(p_claim_ids) then
    raise exception 'Only a pending, unpaid claim in an open GO can be changed';
  end if;
  if p_action = 'delete' then
    insert into claim_edit_log (username, action, claim_id, sub_item_id, go_id, item, detail, before)
    select v_user, 'delete', c.id, c.sub_item_id, si.go_id, g.name || ' — ' || si.name,
           coalesce(m.name, v.name), to_jsonb(c)
      from claims c join sub_items si on si.id = c.sub_item_id join gos g on g.id = si.go_id
      left join members m on m.id = c.member_id left join versions v on v.id = c.version_id
     where c.id = any(p_claim_ids);
    delete from claims where id = any(p_claim_ids) and username = v_user and status = 'pending';
    get diagnostics v_n = row_count;
    return jsonb_build_object('ok', true, 'deleted', v_n);
  end if;
  if cardinality(p_claim_ids) <> 1 then raise exception 'One claim at a time'; end if;
  select * into v_claim from claims where id = p_claim_ids[1];
  if v_claim.set_id is not null or v_claim.is_ot then
    raise exception 'Set claims can only be deleted — delete and claim again';
  end if;
  if p_action = 'qty' then
    if p_qty is null or p_qty < 1 or p_qty >= coalesce(v_claim.qty, 1) then
      raise exception 'Qty can only go down, to at least 1';
    end if;
    update claims set qty = p_qty where id = v_claim.id returning * into v_after;
  elsif p_action = 'member' then
    if v_claim.member_id is null then raise exception 'This item has no member to change'; end if;
    select id into v_member from members where sub_item_id = v_claim.sub_item_id and name = p_member;
    if v_member is null then raise exception 'Unknown member'; end if;
    if v_member = v_claim.member_id then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update claims set member_id = v_member where id = v_claim.id returning * into v_after;
  else
    raise exception 'Unknown action';
  end if;
  insert into claim_edit_log (username, action, claim_id, sub_item_id, go_id, item, detail, after_detail, before, after)
  select v_user, p_action, v_claim.id, v_claim.sub_item_id, si.go_id, g.name || ' — ' || si.name,
         coalesce(m.name, v.name), case when p_action = 'member' then p_member end,
         to_jsonb(v_claim), to_jsonb(v_after)
    from sub_items si join gos g on g.id = si.go_id
    left join members m on m.id = v_claim.member_id left join versions v on v.id = v_claim.version_id
   where si.id = v_claim.sub_item_id;
  return jsonb_build_object('ok', true, 'action', p_action);
end $$;
