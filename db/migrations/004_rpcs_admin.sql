-- Admin-only RPCs. All are SECURITY DEFINER (bypass RLS), granted to
-- `authenticated` only, and belt-and-braces guarded by assert_admin().

create or replace function assert_admin() returns void
language plpgsql as $$
begin
  if auth.role() is distinct from 'authenticated' then
    raise exception 'forbidden';
  end if;
end $$;

create or replace function secure_set(p_sub_item_id uuid, p_set_no int, p_secured boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_set_id uuid;
begin
  perform assert_admin();
  insert into sets (sub_item_id, set_no,
                    status)
  values (p_sub_item_id, p_set_no,
          case when p_secured then 'secured' else 'open' end::set_status)
  on conflict (sub_item_id, set_no) do update
    set status = case when p_secured then 'secured' else 'open' end::set_status
  returning id into v_set_id;
  update claims
     set status = case when p_secured then 'secured' else 'pending' end::claim_status
   where set_id = v_set_id and status <> 'dropped';
  return jsonb_build_object('ok', true);
end $$;

create or replace function move_claim(p_claim_id uuid, p_set_no int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_claim claims%rowtype; v_set_id uuid;
begin
  perform assert_admin();
  select * into v_claim from claims where id = p_claim_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  insert into sets (sub_item_id, set_no) values (v_claim.sub_item_id, p_set_no)
    on conflict (sub_item_id, set_no) do update set set_no = excluded.set_no
    returning id into v_set_id;
  update claims set set_id = v_set_id where id = p_claim_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function apply_credit(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; v_sum numeric := 0;
begin
  perform assert_admin();
  for r in select * from jsonb_array_elements(coalesce(p->'rows','[]'::jsonb)) loop
    v_sum := v_sum + coalesce((r->>'amount')::numeric, 0);
  end loop;
  if abs(v_sum) > 0.01 then
    return jsonb_build_object('ok', false, 'error', 'unbalanced',
      'message', 'Credit rows do not net to zero.');
  end if;
  for r in select * from jsonb_array_elements(coalesce(p->'rows','[]'::jsonb)) loop
    insert into payments (username, go_id, is_shop, amount, method,
                          transaction_id, status, note)
    values (regexp_replace(trim(p->>'username'), '^@', ''),
            nullif(r->>'go_id','')::uuid, false,
            (r->>'amount')::numeric, 'credit',
            nullif(p->>'transaction_id',''), 'confirmed', nullif(r->>'note',''));
  end loop;
  update claims set payment_status = 'paid'
   where id in (select (jsonb_array_elements_text(coalesce(p->'paid_claim_ids','[]'::jsonb)))::uuid);
  update claims set payment_status = 'unpaid'
   where id in (select (jsonb_array_elements_text(coalesce(p->'unpaid_claim_ids','[]'::jsonb)))::uuid);
  return jsonb_build_object('ok', true, 'transaction_id', p->>'transaction_id');
end $$;

create or replace function reverse_credit(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  delete from payments
   where transaction_id = p->>'transaction_id' and method = 'credit';
  update claims set payment_status = 'paid'
   where id in (select (jsonb_array_elements_text(coalesce(p->'paid_claim_ids','[]'::jsonb)))::uuid);
  update claims set payment_status = 'unpaid'
   where id in (select (jsonb_array_elements_text(coalesce(p->'unpaid_claim_ids','[]'::jsonb)))::uuid);
  return jsonb_build_object('ok', true);
end $$;

create or replace function confirm_payment(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  update payments set
    status         = coalesce((p->>'status')::payment_state, status),
    amount         = coalesce((p->>'amount')::numeric, amount),
    username       = coalesce(nullif(p->>'username',''), username),
    method         = coalesce(nullif(p->>'method',''), method),
    transaction_id = coalesce(nullif(p->>'transaction_id',''), transaction_id),
    note           = coalesce(p->>'note', note)
  where id = (p->>'payment_id')::uuid;
  if p->>'status' = 'confirmed' then
    if coalesce((p->>'is_shop')::boolean, false) then
      update shop_orders set payment_status = 'paid'
       where id in (select (jsonb_array_elements_text(coalesce(p->'paid_ids','[]'::jsonb)))::uuid);
      update shop_orders set payment_status = 'unpaid'
       where id in (select (jsonb_array_elements_text(coalesce(p->'unpaid_ids','[]'::jsonb)))::uuid);
    else
      update claims set payment_status = 'paid'
       where id in (select (jsonb_array_elements_text(coalesce(p->'paid_ids','[]'::jsonb)))::uuid);
      update claims set payment_status = 'unpaid'
       where id in (select (jsonb_array_elements_text(coalesce(p->'unpaid_ids','[]'::jsonb)))::uuid);
    end if;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function save_go(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_go_id uuid; si jsonb; v_si_id uuid; v_si_ids uuid[] := '{}';
  keep_ids uuid[] := '{}'; nm text; pos int; blocked text;
begin
  perform assert_admin();
  if coalesce(p->>'go_id','') = '' then
    insert into gos (name, artist, type, status, deadline, payment_deadline, min_secure)
    values (p->>'name', nullif(p->>'artist',''),
            coalesce((p->>'type')::go_type, 'photocard'),
            coalesce((p->>'status')::go_status, 'open'),
            nullif(p->>'deadline','')::timestamptz,
            nullif(p->>'payment_deadline','')::timestamptz,
            coalesce((p->>'min_secure')::int, 7))
    returning id into v_go_id;
  else
    v_go_id := (p->>'go_id')::uuid;
    update gos set
      name             = coalesce(p->>'name', name),
      artist           = coalesce(nullif(p->>'artist',''), artist),
      status           = coalesce((p->>'status')::go_status, status),
      deadline         = case when p ? 'deadline'
                           then nullif(p->>'deadline','')::timestamptz else deadline end,
      payment_deadline = case when p ? 'payment_deadline'
                           then nullif(p->>'payment_deadline','')::timestamptz else payment_deadline end,
      min_secure       = coalesce((p->>'min_secure')::int, min_secure)
    where id = v_go_id;
  end if;

  if p ? 'sub_items' then
    pos := 0;
    for si in select * from jsonb_array_elements(p->'sub_items') loop
      if coalesce(si->>'id','') = '' then
        insert into sub_items (go_id, name, kind, order_mode, batch_size, price,
                               ot_price, min_secure, image_url, position)
        values (v_go_id, si->>'name', (si->>'kind')::sub_item_kind,
                coalesce((si->>'order_mode')::order_mode, 'set'),
                nullif(si->>'batch_size','')::int,
                coalesce((si->>'price')::numeric, 0),
                coalesce((si->>'ot_price')::numeric, 0),
                nullif(si->>'min_secure','')::int,
                nullif(si->>'image_url',''), pos)
        returning id into v_si_id;
      else
        v_si_id := (si->>'id')::uuid;
        update sub_items set
          name       = si->>'name',
          kind       = (si->>'kind')::sub_item_kind,
          order_mode = coalesce((si->>'order_mode')::order_mode, 'set'),
          batch_size = nullif(si->>'batch_size','')::int,
          price      = coalesce((si->>'price')::numeric, 0),
          ot_price   = coalesce((si->>'ot_price')::numeric, 0),
          min_secure = nullif(si->>'min_secure','')::int,
          image_url  = nullif(si->>'image_url',''),
          position   = pos
        where id = v_si_id and go_id = v_go_id;
      end if;
      -- Sync members/versions by name (insert new, delete removed-without-claims).
      delete from members m where m.sub_item_id = v_si_id
        and not (m.name = any(array(select jsonb_array_elements_text(coalesce(si->'members','[]'::jsonb)))))
        and not exists (select 1 from claims c where c.member_id = m.id);
      delete from versions v where v.sub_item_id = v_si_id
        and not (v.name = any(array(select jsonb_array_elements_text(coalesce(si->'versions','[]'::jsonb)))))
        and not exists (select 1 from claims c where c.version_id = v.id);
      insert into members (sub_item_id, name, position)
        select v_si_id, x.name, x.ord - 1
          from jsonb_array_elements_text(coalesce(si->'members','[]'::jsonb))
               with ordinality as x(name, ord)
      on conflict (sub_item_id, name) do update set position = excluded.position;
      insert into versions (sub_item_id, name, position)
        select v_si_id, x.name, x.ord - 1
          from jsonb_array_elements_text(coalesce(si->'versions','[]'::jsonb))
               with ordinality as x(name, ord)
      on conflict (sub_item_id, name) do update set position = excluded.position;
      keep_ids := keep_ids || v_si_id;
      v_si_ids := v_si_ids || v_si_id;
      pos := pos + 1;
    end loop;
    -- Deleting a sub-item with live claims is blocked (deviation 7).
    select s.name into blocked from sub_items s
     where s.go_id = v_go_id and not (s.id = any(keep_ids))
       and exists (select 1 from claims c where c.sub_item_id = s.id)
     limit 1;
    if blocked is not null then
      raise exception 'sub-item "%" still has claims — delete its claims first', blocked;
    end if;
    delete from sub_items s where s.go_id = v_go_id and not (s.id = any(keep_ids));
  end if;

  return jsonb_build_object('ok', true, 'go_id', v_go_id,
                            'sub_item_ids', to_jsonb(v_si_ids));
end $$;

revoke execute on function secure_set(uuid,int,boolean), move_claim(uuid,int),
  apply_credit(jsonb), reverse_credit(jsonb), confirm_payment(jsonb), save_go(jsonb)
  from public, anon;
grant execute on function secure_set(uuid,int,boolean), move_claim(uuid,int),
  apply_credit(jsonb), reverse_credit(jsonb), confirm_payment(jsonb), save_go(jsonb)
  to authenticated;
