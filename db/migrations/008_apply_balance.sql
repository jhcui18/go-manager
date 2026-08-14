-- Anon-callable, server-computed balance apply. Replaces the admin-only apply_credit
-- path for joiner self-serve: takes only (username, target GO) and recomputes the
-- owed-unit model, balance, greedy spend, and source draw entirely server-side —
-- the client can no longer hand in amounts/rows to write. Mirrors index.html's
-- paymentOwedUnits/ownedUnitsFromClaims, applyStoreCredit, drawSources exactly.
create or replace function apply_balance(p_username citext, p_go_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_username text;
  v_go_name text;
  v_balance numeric := 0;
  v_spent numeric := 0;
  v_covered_ids uuid[] := '{}';
  v_src_ids uuid[];
  v_src_names text[];
  v_src_credits numeric[];
  v_sources jsonb := '[]'::jsonb;
  v_note_names text[] := '{}';
  v_need numeric;
  v_take numeric;
  v_take_rounded numeric;
  v_total_drawn numeric := 0;
  v_tx text;
  v_unit record;
  i int;
begin
  v_username := regexp_replace(btrim(p_username::text), '^@', '');

  -- Serialize concurrent balance applies for the same user.
  perform pg_advisory_xact_lock(hashtextextended(lower(v_username), 0));

  select name into v_go_name from gos where id = p_go_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_go');
  end if;

  -- Balance = sum of credit across all of this user's OTHER source scopes (their
  -- other GOs, keyed by which GOs they have any claim in, + the shop), excluding
  -- the target GO. credit(scope) = greatest(0, paid - securedValue).
  with claim_gos as (
    select distinct si.go_id
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username
  ),
  owed as (
    -- (a) secured non-OT slot claims: one unit each, value = sub_item.price
    select si.go_id, si.price as value, (c.payment_status = 'paid') as is_paid
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username and c.set_id is not null
       and c.is_ot = false and c.status = 'secured'
    union all
    -- (b) secured OT claims grouped per set: one unit, value = sub_item.ot_price
    select si.go_id, si.ot_price, bool_and(c.payment_status = 'paid')
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username and c.set_id is not null
       and c.is_ot = true and c.status = 'secured'
     group by c.set_id, si.go_id, si.ot_price
    union all
    -- (c) secured claims-based claims: one unit each, value = price*qty
    select si.go_id, si.price * c.qty, (c.payment_status = 'paid')
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username and c.set_id is null and c.status = 'secured'
  ),
  go_secured as (
    select go_id, sum(value) as secured from owed group by go_id
  ),
  go_paid as (
    select go_id, sum(amount) as paid from payments
     where username = v_username and status = 'confirmed'
       and is_shop = false and go_id is not null
     group by go_id
  ),
  go_scopes as (
    select cg.go_id, g.name as go_name,
           greatest(0, coalesce(gp.paid, 0) - coalesce(gs.secured, 0)) as credit
      from claim_gos cg
      join gos g on g.id = cg.go_id
      left join go_secured gs on gs.go_id = cg.go_id
      left join go_paid gp on gp.go_id = cg.go_id
  ),
  shop_scope as (
    select null::uuid as go_id, 'Shop'::text as go_name,
           greatest(0,
             coalesce((select sum(amount) from payments
                        where username = v_username and status = 'confirmed' and is_shop = true), 0)
             - coalesce((select sum(unit_price * qty) from shop_orders
                          where username = v_username), 0)
           ) as credit
  ),
  all_scopes as (
    select * from go_scopes
    union all
    select * from shop_scope
  )
  select
    coalesce(sum(credit) filter (where credit > 0.001), 0),
    array_agg(go_id order by credit desc) filter (where credit > 0.001),
    array_agg(go_name order by credit desc) filter (where credit > 0.001),
    array_agg(credit order by credit desc) filter (where credit > 0.001)
  into v_balance, v_src_ids, v_src_names, v_src_credits
  from all_scopes
  where go_id is distinct from p_go_id;

  -- Greedy spend: cover whole UNPAID units of the target GO, in display order
  -- (min claim created_at, then min claim id::text). A too-big unit is skipped,
  -- not a hard stop — later cheaper units are still checked.
  for v_unit in
    select value, ids, is_paid, min_created, min_idtext from (
      select si.price as value, array[c.id] as ids, (c.payment_status = 'paid') as is_paid,
             c.created_at as min_created, c.id::text as min_idtext
        from claims c join sub_items si on si.id = c.sub_item_id
       where c.username = v_username and si.go_id = p_go_id
         and c.set_id is not null and c.is_ot = false and c.status = 'secured'
      union all
      select si.ot_price, array_agg(c.id order by c.id), bool_and(c.payment_status = 'paid'),
             min(c.created_at), min(c.id::text)
        from claims c join sub_items si on si.id = c.sub_item_id
       where c.username = v_username and si.go_id = p_go_id
         and c.set_id is not null and c.is_ot = true and c.status = 'secured'
       group by c.set_id, si.ot_price
      union all
      select si.price * c.qty, array[c.id], (c.payment_status = 'paid'),
             c.created_at, c.id::text
        from claims c join sub_items si on si.id = c.sub_item_id
       where c.username = v_username and si.go_id = p_go_id
         and c.set_id is null and c.status = 'secured'
    ) u
    order by min_created, min_idtext
  loop
    if v_unit.is_paid then
      continue;
    end if;
    if v_spent + v_unit.value <= v_balance + 0.001 then
      v_spent := v_spent + v_unit.value;
      v_covered_ids := v_covered_ids || v_unit.ids;
    end if;
  end loop;

  if v_spent <= 0.001 then
    return jsonb_build_object('ok', true, 'spent', 0, 'balance', v_balance);
  end if;

  v_tx := 'bal_' || floor(extract(epoch from clock_timestamp()))::bigint
          || '_' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);

  -- Draw the spend from sources, largest credit first, capped per source, rounded
  -- to cents. One payments row per source (negative, on that scope) plus one row
  -- on the target (positive) — written below — so the ledger nets to zero.
  v_need := v_spent;
  for i in 1 .. coalesce(array_length(v_src_ids, 1), 0) loop
    exit when v_need <= 0.001;
    v_take := least(v_src_credits[i], v_need);
    if v_take > 0.001 then
      v_take_rounded := round(v_take, 2);
      v_sources := v_sources || jsonb_build_object('go_id', coalesce(v_src_ids[i]::text, 'shop'), 'amount', v_take_rounded);
      v_note_names := v_note_names || coalesce(v_src_names[i], 'Shop');
      v_total_drawn := v_total_drawn + v_take_rounded;
      insert into payments (username, go_id, is_shop, amount, method, transaction_id, status, note)
      values (v_username, v_src_ids[i], v_src_ids[i] is null, -v_take_rounded, 'credit', v_tx, 'confirmed',
              'Credit applied to ' || v_go_name);
      v_need := v_need - v_take;
    end if;
  end loop;

  insert into payments (username, go_id, is_shop, amount, method, transaction_id, status, note)
  values (v_username, p_go_id, false, v_total_drawn, 'credit', v_tx, 'confirmed',
          'From credit on ' || array_to_string(v_note_names, ', '));

  update claims set payment_status = 'paid' where id = any(v_covered_ids);

  return jsonb_build_object('ok', true, 'spent', v_total_drawn, 'balance', v_balance,
    'paid_claim_ids', to_jsonb(v_covered_ids), 'transaction_id', v_tx, 'sources', v_sources);
end $$;

revoke execute on function apply_balance(citext, uuid) from public;
grant execute on function apply_balance(citext, uuid) to anon, authenticated;
