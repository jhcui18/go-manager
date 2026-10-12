-- 043: free-text notes on GOs and sub-items, in two flavours.
--
--   description  joiner-facing. Lives on gos / sub_items, which anon already
--                reads with qual = true, so joiners get it for free.
--   admin_notes  private. A separate table with NO anon policy and NO anon
--                grant. A private column on gos / sub_items would be fetchable
--                by anyone holding the publishable key, since anon_read is
--                SELECT over the whole row — hence the separate table.
--
-- save_go writes all four fields in one admin round trip. Both note fields are
-- only touched when the payload carries the key, so a partial save cannot wipe
-- a note the form did not send.
--
-- NOTE ON SHAPE: save_go is split into save_go_item / save_go_names / save_go.
-- That is not a design preference — the MCP SQL endpoint rejects statements
-- over roughly 2 KB with 'Invalid or expired requestState', and the one-piece
-- function could not be applied. The split keeps each statement applyable and
-- happens to isolate the per-item work. keep_ids and v_si_ids were always the
-- same array in the original, so the outer function now carries one.

alter table gos       add column if not exists description text;
alter table sub_items add column if not exists description text;

create table if not exists admin_notes (
  id          uuid primary key default gen_random_uuid(),
  go_id       uuid references gos(id)       on delete cascade,
  sub_item_id uuid references sub_items(id) on delete cascade,
  body        text not null default '',
  updated_at  timestamptz not null default now(),
  constraint admin_notes_one_target check ((go_id is null) <> (sub_item_id is null))
);
create unique index if not exists admin_notes_go_uniq on admin_notes(go_id)       where go_id is not null;
create unique index if not exists admin_notes_si_uniq on admin_notes(sub_item_id) where sub_item_id is not null;

alter table admin_notes enable row level security;
drop policy if exists admin_all on admin_notes;
create policy admin_all on admin_notes for all to authenticated using (true) with check (true);
revoke all on admin_notes from anon;
grant select, insert, update, delete on admin_notes to authenticated;

-- Upsert one private note. A blank body deletes the row, so clearing the box
-- in the editor leaves no empty record behind. Two partial unique indexes
-- cannot both be an on-conflict target, so this updates then inserts.
create or replace function set_admin_note(p_go_id uuid, p_sub_item_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  if (p_go_id is null) = (p_sub_item_id is null) then
    raise exception 'set_admin_note needs exactly one of go_id / sub_item_id';
  end if;
  if coalesce(btrim(p_body), '') = '' then
    delete from admin_notes
     where (p_go_id is not null and go_id = p_go_id)
        or (p_sub_item_id is not null and sub_item_id = p_sub_item_id);
    return;
  end if;
  if p_go_id is not null then
    update admin_notes set body = p_body, updated_at = now() where go_id = p_go_id;
    if not found then insert into admin_notes (go_id, body) values (p_go_id, p_body); end if;
  else
    update admin_notes set body = p_body, updated_at = now() where sub_item_id = p_sub_item_id;
    if not found then insert into admin_notes (sub_item_id, body) values (p_sub_item_id, p_body); end if;
  end if;
end $$;

revoke execute on function set_admin_note(uuid, uuid, text) from public, anon;
grant   execute on function set_admin_note(uuid, uuid, text) to authenticated;

-- One sub-item: insert or update, plus its private note. Body as in save_go
-- before this migration, with `description` added.
create or replace function save_go_item(p_go_id uuid, si jsonb, p_pos int)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_si_id uuid;
begin
  perform assert_admin();
  if coalesce(si->>'id','') = '' then
    insert into sub_items (go_id,name,kind,order_mode,batch_size,price,ot_price,min_secure,image_url,position,description)
    values (p_go_id, si->>'name', (si->>'kind')::sub_item_kind,
            coalesce((si->>'order_mode')::order_mode,'set'), nullif(si->>'batch_size','')::int,
            coalesce((si->>'price')::numeric,0), coalesce((si->>'ot_price')::numeric,0),
            nullif(si->>'min_secure','')::int, nullif(si->>'image_url',''), p_pos,
            nullif(si->>'description',''))
    returning id into v_si_id;
  else
    v_si_id := (si->>'id')::uuid;
    update sub_items set name = si->>'name', kind = (si->>'kind')::sub_item_kind,
      order_mode = coalesce((si->>'order_mode')::order_mode,'set'),
      batch_size = nullif(si->>'batch_size','')::int,
      price = coalesce((si->>'price')::numeric,0),
      ot_price = coalesce((si->>'ot_price')::numeric,0),
      min_secure = nullif(si->>'min_secure','')::int,
      image_url = nullif(si->>'image_url',''), position = p_pos,
      description = case when si ? 'description' then nullif(si->>'description','') else description end
    where id = v_si_id and go_id = p_go_id;
    if not found then raise exception 'sub-item % does not belong to this GO', v_si_id; end if;
  end if;
  if si ? 'admin_note' then perform set_admin_note(null, v_si_id, si->>'admin_note'); end if;
  return v_si_id;
end $$;

-- Members and versions for one sub-item: insert new, delete removed-without-claims.
-- Unchanged from the original save_go. Renaming is still not expressible here:
-- the sync is by name, so a renamed member with claims forks into a second row.
create or replace function save_go_names(p_si_id uuid, si jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  delete from members m where m.sub_item_id = p_si_id
    and not (m.name = any(array(select jsonb_array_elements_text(coalesce(si->'members','[]'::jsonb)))))
    and not exists (select 1 from claims c where c.member_id = m.id);
  delete from versions v where v.sub_item_id = p_si_id
    and not (v.name = any(array(select jsonb_array_elements_text(coalesce(si->'versions','[]'::jsonb)))))
    and not exists (select 1 from claims c where c.version_id = v.id);
  insert into members (sub_item_id, name, position)
    select p_si_id, x.name, x.ord - 1
      from jsonb_array_elements_text(coalesce(si->'members','[]'::jsonb)) with ordinality as x(name, ord)
  on conflict (sub_item_id, name) do update set position = excluded.position;
  insert into versions (sub_item_id, name, position)
    select p_si_id, x.name, x.ord - 1
      from jsonb_array_elements_text(coalesce(si->'versions','[]'::jsonb)) with ordinality as x(name, ord)
  on conflict (sub_item_id, name) do update set position = excluded.position;
end $$;

create or replace function save_go(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_go_id uuid; si jsonb; v_si_id uuid; v_si_ids uuid[] := '{}'; pos int; blocked text;
begin
  perform assert_admin();
  if coalesce(p->>'go_id','') = '' then
    insert into gos (name,artist,type,status,deadline,payment_deadline,min_secure,description)
    values (p->>'name', nullif(p->>'artist',''), coalesce((p->>'type')::go_type,'photocard'),
            coalesce((p->>'status')::go_status,'open'), nullif(p->>'deadline','')::timestamptz,
            nullif(p->>'payment_deadline','')::timestamptz, coalesce((p->>'min_secure')::int,7),
            nullif(p->>'description',''))
    returning id into v_go_id;
  else
    v_go_id := (p->>'go_id')::uuid;
    update gos set name = coalesce(p->>'name', name),
      artist = coalesce(nullif(p->>'artist',''), artist),
      status = coalesce((p->>'status')::go_status, status),
      deadline = case when p ? 'deadline' then nullif(p->>'deadline','')::timestamptz else deadline end,
      payment_deadline = case when p ? 'payment_deadline' then nullif(p->>'payment_deadline','')::timestamptz else payment_deadline end,
      min_secure = coalesce((p->>'min_secure')::int, min_secure),
      description = case when p ? 'description' then nullif(p->>'description','') else description end
    where id = v_go_id;
  end if;
  if p ? 'admin_note' then perform set_admin_note(v_go_id, null, p->>'admin_note'); end if;
  if p ? 'sub_items' then
    pos := 0;
    for si in select * from jsonb_array_elements(p->'sub_items') loop
      v_si_id := save_go_item(v_go_id, si, pos);
      perform save_go_names(v_si_id, si);
      v_si_ids := v_si_ids || v_si_id;
      pos := pos + 1;
    end loop;
    -- Deleting a sub-item with live claims is blocked (deviation 7).
    select s.name into blocked from sub_items s
     where s.go_id = v_go_id and not (s.id = any(v_si_ids))
       and exists (select 1 from claims c where c.sub_item_id = s.id) limit 1;
    if blocked is not null then
      raise exception 'sub-item "%" still has claims - delete its claims first', blocked;
    end if;
    delete from sub_items s where s.go_id = v_go_id and not (s.id = any(v_si_ids));
  end if;
  return jsonb_build_object('ok', true, 'go_id', v_go_id, 'sub_item_ids', to_jsonb(v_si_ids));
end $$;

revoke execute on function save_go_item(uuid, jsonb, int) from public, anon;
revoke execute on function save_go_names(uuid, jsonb)     from public, anon;
grant   execute on function save_go_item(uuid, jsonb, int) to authenticated;
grant   execute on function save_go_names(uuid, jsonb)     to authenticated;
