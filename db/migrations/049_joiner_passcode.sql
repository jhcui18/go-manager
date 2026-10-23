-- 049: per-joiner passcode for My-orders self-edits (047). Joiners voted for it
-- over log-only. The first edit under a handle asks the joiner to create a code
-- (4-20 chars, bcrypt-hashed); every later edit must send it. Five wrong tries
-- lock the handle for 15 minutes. Admin resets by deleting the row (authenticated
-- grant) — the joiner then creates a new one on their next edit.
-- Passcode failures are RETURNED as {ok:false, error} instead of raised, because a
-- raise would roll back the fail_count bump in the same transaction.
create table if not exists joiner_passcodes (
  username   citext primary key,
  code_hash  text not null,
  set_at     timestamptz not null default now(),
  fail_count int not null default 0,
  last_fail  timestamptz
);
alter table joiner_passcodes enable row level security;
drop policy if exists admin_all on joiner_passcodes;
create policy admin_all on joiner_passcodes for all to authenticated using (true) with check (true);
revoke all on joiner_passcodes from anon;
grant select, delete on joiner_passcodes to authenticated;

create or replace function set_my_passcode(p_username citext, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user citext := lower(regexp_replace(trim(p_username::text), '^@', ''));
        v_code text := trim(coalesce(p_code, ''));
begin
  if v_user = '' then raise exception 'No username'; end if;
  if length(v_code) < 4 or length(v_code) > 20 then
    raise exception 'Passcode must be 4 to 20 characters';
  end if;
  if exists (select 1 from joiner_passcodes where username = v_user) then
    raise exception 'A passcode is already set for this username — DM Carol to reset it';
  end if;
  insert into joiner_passcodes (username, code_hash)
  values (v_user, extensions.crypt(v_code, extensions.gen_salt('bf', 6)));
  return jsonb_build_object('ok', true);
end $$;

-- Internal: null when the code is right, else an error key. Bumps fail_count.
create or replace function check_joiner_passcode(p_user citext, p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare r joiner_passcodes%rowtype;
begin
  select * into r from joiner_passcodes where username = p_user;
  if not found then return 'no_passcode'; end if;
  if r.fail_count >= 5 and r.last_fail > now() - interval '15 minutes' then return 'locked'; end if;
  if p_code is null or r.code_hash <> extensions.crypt(trim(p_code), r.code_hash) then
    update joiner_passcodes
       set fail_count = case when last_fail is null or last_fail < now() - interval '15 minutes' then 1 else fail_count + 1 end,
           last_fail = now()
     where username = p_user;
    return 'wrong_passcode';
  end if;
  if r.fail_count > 0 then update joiner_passcodes set fail_count = 0 where username = p_user; end if;
  return null;
end $$;

drop function if exists edit_my_pending_claim(uuid[], citext, text, int, text);
create or replace function edit_my_pending_claim(p_claim_ids uuid[], p_username citext,
                                                 p_action text, p_qty int default null,
                                                 p_member text default null, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user citext := lower(regexp_replace(trim(p_username::text), '^@', ''));
        v_n int; v_claim claims%rowtype; v_member uuid; v_after claims%rowtype; v_chk text;
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
  v_chk := check_joiner_passcode(v_user, p_code);
  if v_chk is not null then return jsonb_build_object('ok', false, 'error', v_chk); end if;
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

revoke execute on function check_joiner_passcode(citext, text) from public, anon, authenticated;
revoke execute on function set_my_passcode(citext, text),
  edit_my_pending_claim(uuid[], citext, text, int, text, text) from public;
grant execute on function set_my_passcode(citext, text),
  edit_my_pending_claim(uuid[], citext, text, int, text, text) to anon, authenticated;

-- Page gate for My orders: the page asks for the passcode before it renders a
-- handle's orders (admin session skips it). This only verifies; the reads still
-- go through the anon views, so it stops joiners peeking at each other, not a
-- caller with the public key. A real gate (reads behind a passcode-checked RPC)
-- is a later migration.
create or replace function verify_my_passcode(p_username citext, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user citext := lower(regexp_replace(trim(p_username::text), '^@', ''));
        v_chk text;
begin
  if v_user = '' then raise exception 'No username'; end if;
  v_chk := check_joiner_passcode(v_user, p_code);
  if v_chk is not null then return jsonb_build_object('ok', false, 'error', v_chk); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function verify_my_passcode(citext, text) from public;
grant execute on function verify_my_passcode(citext, text) to anon, authenticated;
