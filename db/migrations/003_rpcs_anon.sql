-- All four are SECURITY DEFINER (bypass RLS) and force status fields server-side.

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
    if v_go.status = 'closed' then
      return jsonb_build_object('ok', false, 'error', 'closed',
        'message', 'This GO is closed and no longer accepting claims.');
    end if;
    if v_si.closed then
      return jsonb_build_object('ok', false, 'error', 'closed',
        'message', 'This item is closed and no longer accepting claims.');
    end if;
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

    v_is_set := v_si.kind in ('photocard','member','member-set')
                and v_si.order_mode = 'set' and v_member.id is not null;
    if v_is_set then
      if coalesce((c->>'is_ot')::boolean, false) then
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
      else
        -- First set number where this member's slot is free (dropped claims occupy).
        select min(n) into v_set_no
          from generate_series(1,
            (select coalesce(max(set_no),0)+1 from sets where sub_item_id = v_si.id)) n
         where not exists (
           select 1 from claims cl join sets s on s.id = cl.set_id
            where s.sub_item_id = v_si.id and s.set_no = n
              and cl.member_id = v_member.id);
      end if;
      insert into sets (sub_item_id, set_no) values (v_si.id, v_set_no)
        on conflict (sub_item_id, set_no) do update set set_no = excluded.set_no
        returning id into v_set_id;
    end if;

    insert into claims (sub_item_id, username, email, set_id, member_id, version_id,
                        is_ot, qty, assigned_version, status, payment_status, fulfillment)
    values (v_si.id,
            regexp_replace(trim(c->>'username'), '^@', ''),
            nullif(c->>'email',''),
            v_set_id, v_member.id, v_version.id,
            coalesce((c->>'is_ot')::boolean, false),
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

create or replace function submit_payment(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into payments (username, go_id, is_shop, amount, method,
                        transaction_id, proof_url, email, status)
  values (regexp_replace(trim(p->>'username'), '^@', ''),
          case when p->>'go_id' = 'shop' then null
               else nullif(p->>'go_id','')::uuid end,
          coalesce(p->>'go_id','') = 'shop',
          (p->>'amount')::numeric,
          p->>'method',
          nullif(p->>'transaction_id',''),
          nullif(p->>'proof_url',''),
          nullif(p->>'email',''),
          'pending')
  returning id into v_id;
  return jsonb_build_object('ok', true, 'payment_id', v_id);
end $$;

create or replace function submit_shipping(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; it jsonb;
begin
  insert into shipping_requests (username, full_name, address1, address2, city,
                                 state, postal, country, notes, email)
  values (regexp_replace(trim(p->>'username'), '^@', ''),
          p->>'full_name', p->>'address1', nullif(p->>'address2',''),
          p->>'city', p->>'state', p->>'postal', p->>'country',
          nullif(p->>'notes',''), nullif(p->>'email',''))
  returning id into v_id;
  for it in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    insert into shipping_request_items (request_id, go_id, description, qty)
    values (v_id, nullif(it->>'go_id','')::uuid, it->>'description',
            greatest(coalesce((it->>'qty')::int,1),1));
  end loop;
  return jsonb_build_object('ok', true, 'request_id', v_id);
end $$;

create or replace function place_shop_order(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_listing listings%rowtype;
  v_variant listing_variants%rowtype;
  v_qty int := greatest(coalesce((p->>'qty')::int,1),1);
  v_id uuid;
begin
  select * into v_listing from listings
   where id = (p->>'listing_id')::uuid for update;
  if not found or v_listing.status <> 'active' then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  if coalesce(p->>'variant_id','') <> '' then
    select * into v_variant from listing_variants
     where id = (p->>'variant_id')::uuid and listing_id = v_listing.id for update;
    if not found or v_variant.qty < v_qty then
      return jsonb_build_object('ok', false, 'error', 'stock');
    end if;
    update listing_variants set qty = qty - v_qty where id = v_variant.id;
  else
    if coalesce(v_listing.qty, 0) < v_qty then
      return jsonb_build_object('ok', false, 'error', 'stock');
    end if;
    update listings set qty = qty - v_qty where id = v_listing.id;
  end if;
  insert into shop_orders (listing_id, variant_id, username, email, qty,
                           unit_price, payment_status, fulfillment)
  values (v_listing.id, v_variant.id,
          regexp_replace(trim(p->>'username'), '^@', ''),
          nullif(p->>'email',''), v_qty, v_listing.price, 'unpaid', 'Ready')
  returning id into v_id;
  return jsonb_build_object('ok', true, 'order_id', v_id);
end $$;

revoke execute on function submit_claim(jsonb),
  submit_payment(jsonb), submit_shipping(jsonb), place_shop_order(jsonb) from public;
grant execute on function submit_claim(jsonb),
  submit_payment(jsonb), submit_shipping(jsonb), place_shop_order(jsonb)
  to anon, authenticated;
