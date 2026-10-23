-- 047: a joiner edits their own Pending claim on My orders. One anon RPC, same
-- trust model as 030 (the joiner is whoever typed the handle). Allowed only while
-- the claim is pending AND unpaid AND its item and GO are still open:
--   * delete  — the whole row (an OT set passes all its ids at once). Set
--               columns repack via the 029 trigger.
--   * qty     — lower the qty of a non-set claim (never raise it).
--   * member  — change the member of a non-set claim (merch member items,
--               batch POBs). Set-slot claims can't move: delete and re-claim.
-- Secured, paid, dropped, archived, closed-item and closed-GO claims all refuse,
-- and so does any claim whose fulfillment already moved past Pending (ordered
-- before it was marked secured).
create or replace function edit_my_pending_claim(p_claim_ids uuid[], p_username citext,
                                                 p_action text, p_qty int default null,
                                                 p_member text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user citext := lower(regexp_replace(trim(p_username::text), '^@', ''));
        v_n int; v_claim claims%rowtype; v_member uuid;
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
    update claims set qty = p_qty where id = v_claim.id;
    return jsonb_build_object('ok', true, 'qty', p_qty);
  end if;
  if p_action = 'member' then
    if v_claim.member_id is null then raise exception 'This item has no member to change'; end if;
    select id into v_member from members where sub_item_id = v_claim.sub_item_id and name = p_member;
    if v_member is null then raise exception 'Unknown member'; end if;
    if v_member = v_claim.member_id then return jsonb_build_object('ok', true, 'unchanged', true); end if;
    update claims set member_id = v_member where id = v_claim.id;
    return jsonb_build_object('ok', true, 'member', p_member);
  end if;
  raise exception 'Unknown action';
end $$;

revoke execute on function edit_my_pending_claim(uuid[], citext, text, int, text) from public;
grant execute on function edit_my_pending_claim(uuid[], citext, text, int, text) to anon, authenticated;
