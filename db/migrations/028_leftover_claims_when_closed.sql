-- 028: closed POBs must still accept LEFTOVER fills — an empty member slot in a
-- whole-set-secured set (the GO already committed to buying the full set). The
-- client has always allowed these (isPobClosed/leftoverSlotOpen), but the RPC
-- rejected any closed GO/item before even resolving the member, so the tiles
-- offered spots the submit then refused. The closed check now runs after
-- member/OT resolution: set-shaped non-OT claims may land in the lowest-numbered
-- secured set whose slot for that member is free; everything else on a closed
-- target still rejects. Dropped claims keep occupying their slot (matches the
-- board), and no new sets are ever created on a closed item.
create or replace function submit_claim(p_claims jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c jsonb;
  v_si sub_items%rowtype;
  v_go gos%rowtype;
  v_member members%rowtype;
  v_version versions%rowtype;
  v_set_id uuid; v_set_no int; v_new_id uuid;
  v_ids uuid[] := '{}'; v_set_nos int[] := '{}';
  v_is_set boolean;
  v_closed boolean;
  v_is_ot boolean;
  -- OT full-set grouping state within this submission (per sub-item):
  v_ot_si uuid; v_ot_set_no int; v_ot_seen text[] := '{}';
begin
  if p_claims is null or jsonb_array_length(p_claims) = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty');
  end if;
  for c in select * from jsonb_array_elements(p_claims) loop
    select * into v_si from sub_items where id = (c->>'sub_item_id')::uuid;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'no_sub_item');
    end if;
    select * into v_go from gos where id = v_si.go_id;
    v_closed := (v_go.status = 'closed') or v_si.closed;
    -- Serialize slot assignment per sub-item (successor of LockService).
    perform pg_advisory_xact_lock(hashtextextended(v_si.id::text, 0));

    v_member := null; v_version := null; v_set_id := null; v_set_no := null;
    if coalesce(c->>'member','') <> '' then
      select * into v_member from members
       where sub_item_id = v_si.id and name = c->>'member';
    end if;
    if coalesce(c->>'version','') <> '' then
      select * into v_version from versions
       where sub_item_id = v_si.id and name = c->>'version';
    end if;

    v_is_ot := coalesce((c->>'is_ot')::boolean, false);
    v_is_set := v_si.kind in ('photocard','member','member-set')
                and v_si.order_mode = 'set' and v_member.id is not null;

    -- Closed target: only a set-shaped, non-OT leftover fill may proceed.
    if v_closed and (not v_is_set or v_is_ot) then
      return jsonb_build_object('ok', false, 'error', 'closed',
        'message', case when v_go.status = 'closed'
          then 'This GO is closed and no longer accepting claims.'
          else 'This item is closed and no longer accepting claims.' end);
    end if;

    if v_is_set then
      if v_closed then
        -- Leftover fill: lowest-numbered whole-set-secured set with this
        -- member's slot free (dropped claims still occupy their slot).
        select s.set_no, s.id into v_set_no, v_set_id
          from sets s
         where s.sub_item_id = v_si.id and s.status = 'secured'
           and not exists (select 1 from claims cl
                            where cl.set_id = s.id and cl.member_id = v_member.id)
         order by s.set_no
         limit 1;
        if v_set_id is null then
          return jsonb_build_object('ok', false, 'error', 'closed',
            'message', 'This item is closed — no leftover secured spot for ' || v_member.name || '.');
        end if;
      elsif v_is_ot then
        -- OT full sets: own fresh set number per group; a new group starts when the
        -- sub-item changes or the current OT set already holds this member.
        if v_ot_si is distinct from v_si.id or v_member.name = any(v_ot_seen) then
          select coalesce(max(s.set_no), 0) + 1 into v_set_no
            from sets s
           where s.sub_item_id = v_si.id
             and exists (select 1 from claims cl where cl.set_id = s.id);
          if v_ot_si = v_si.id and v_ot_set_no is not null then
            v_set_no := greatest(v_set_no, v_ot_set_no + 1);
          end if;
          while exists (select 1 from sets s join claims cl on cl.set_id = s.id
                         where s.sub_item_id = v_si.id and s.set_no = v_set_no) loop
            v_set_no := v_set_no + 1;
          end loop;
          v_ot_si := v_si.id; v_ot_set_no := v_set_no; v_ot_seen := '{}';
        else
          v_set_no := v_ot_set_no;
        end if;
        v_ot_seen := v_ot_seen || v_member.name::text;
        insert into sets (sub_item_id, set_no) values (v_si.id, v_set_no)
          on conflict (sub_item_id, set_no) do update set set_no = excluded.set_no
          returning id into v_set_id;
      else
        -- First set number where this member's slot is free (dropped claims occupy).
        select min(n) into v_set_no
          from generate_series(1,
            (select coalesce(max(set_no),0)+1 from sets where sub_item_id = v_si.id)) n
         where not exists (
           select 1 from claims cl join sets s on s.id = cl.set_id
            where s.sub_item_id = v_si.id and s.set_no = n
              and cl.member_id = v_member.id);
        insert into sets (sub_item_id, set_no) values (v_si.id, v_set_no)
          on conflict (sub_item_id, set_no) do update set set_no = excluded.set_no
          returning id into v_set_id;
      end if;
    end if;

    insert into claims (sub_item_id, username, email, set_id, member_id, version_id,
                        is_ot, qty, assigned_version, status, payment_status, fulfillment)
    values (v_si.id,
            regexp_replace(trim(c->>'username'), '^@', ''),
            nullif(c->>'email',''),
            v_set_id, v_member.id, v_version.id,
            v_is_ot,
            greatest(coalesce((c->>'qty')::int, 1), 1),
            nullif(c->>'assigned_version',''),
            'pending', 'unpaid', 'Pending')
    returning id into v_new_id;
    v_ids := v_ids || v_new_id;
    v_set_nos := v_set_nos || coalesce(v_set_no, 0);
  end loop;
  return jsonb_build_object('ok', true,
    'claim_ids', to_jsonb(v_ids), 'set_nums', to_jsonb(v_set_nos));
end $$;
