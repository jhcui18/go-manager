-- 022: price overrides reach OT full sets. An override stored on any claim row
-- of a set-shaped OT group now overrides the SET price (max across the group's
-- rows wins; null everywhere = si.ot_price as before). The admin UI writes the
-- override to every row of the group so the max is unambiguous. Batch-mode OT
-- rows already priced per-row and were override-aware since 018.
create or replace function apply_balance(p_username citext, p_go_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_username text;
  v_go_name text;
  v_balance numeric := 0;
  v_loose numeric := 0;
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
    return jsonb_build_object('ok', false, 'error', 'no_go', 'spent', 0, 'balance', 0,
      'paid_claim_ids', '[]'::jsonb, 'transaction_id', null, 'sources', '[]'::jsonb);
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
    select si.go_id, coalesce(c.price_override, si.price) as value, (c.payment_status = 'paid') as is_paid
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username and c.status = 'secured' and c.is_ot = false
       and (exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
       and c.member_id is not null and c.set_id is not null
    union all
    select si.go_id, coalesce(max(c.price_override), si.ot_price), bool_and(c.payment_status = 'paid')
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username and c.status = 'secured' and c.is_ot = true
       and (exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
       and c.member_id is not null and c.set_id is not null
     group by c.set_id, si.go_id, si.ot_price
    union all
    select si.go_id, coalesce(c.price_override, si.price) * c.qty, (c.payment_status = 'paid')
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username and c.status = 'secured'
       and not ((exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
                and c.member_id is not null and c.set_id is not null)
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

  -- Loose cash on the TARGET GO: confirmed payments not yet backing a paid unit.
  -- This tops up a part-paid unit; only the remainder is drawn from sources.
  with owed_t as (
    select coalesce(c.price_override, si.price) as value, (c.payment_status = 'paid') as is_paid
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username and si.go_id = p_go_id and c.status = 'secured'
       and c.is_ot = false
       and (exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
       and c.member_id is not null and c.set_id is not null
    union all
    select coalesce(max(c.price_override), si.ot_price), bool_and(c.payment_status = 'paid')
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username and si.go_id = p_go_id and c.status = 'secured'
       and c.is_ot = true
       and (exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
       and c.member_id is not null and c.set_id is not null
     group by c.set_id, si.ot_price
    union all
    select coalesce(c.price_override, si.price) * c.qty, (c.payment_status = 'paid')
      from claims c join sub_items si on si.id = c.sub_item_id
     where c.username = v_username and si.go_id = p_go_id and c.status = 'secured'
       and not ((exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
                and c.member_id is not null and c.set_id is not null)
  )
  select greatest(0,
    coalesce((select sum(amount) from payments
               where username = v_username and status = 'confirmed'
                 and is_shop = false and go_id = p_go_id), 0)
    - coalesce((select sum(value) from owed_t where is_paid), 0))
  into v_loose;

  -- Greedy spend over the target GO's unpaid units, in ownedUnitsFromClaims
  -- order (see 008 for the ordering rationale). Budget = balance + loose cash.
  for v_unit in
    with set_groups as (
      select c.set_id, min(c.created_at) as grp_created, min(c.id::text) as grp_idtext
        from claims c join sub_items si on si.id = c.sub_item_id
       where c.username = v_username and si.go_id = p_go_id and c.status = 'secured'
         and (exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
         and c.member_id is not null and c.set_id is not null
       group by c.set_id
    )
    select value, ids, is_paid from (
      select coalesce(c.price_override, si.price) * c.qty as value, array[c.id] as ids, (c.payment_status = 'paid') as is_paid,
             0 as kind_rank, c.created_at as grp_created, c.id::text as grp_idtext,
             0 as sub_order, c.created_at as own_created, c.id::text as own_idtext
        from claims c join sub_items si on si.id = c.sub_item_id
       where c.username = v_username and si.go_id = p_go_id and c.status = 'secured'
         and not ((exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
                  and c.member_id is not null and c.set_id is not null)
      union all
      select coalesce(max(c.price_override), si.ot_price) as value, array_agg(c.id order by c.created_at, c.id) as ids,
             bool_and(c.payment_status = 'paid') as is_paid,
             1 as kind_rank, sg.grp_created, sg.grp_idtext,
             0 as sub_order, sg.grp_created as own_created, sg.grp_idtext as own_idtext
        from claims c join sub_items si on si.id = c.sub_item_id
        join set_groups sg on sg.set_id = c.set_id
       where c.username = v_username and si.go_id = p_go_id and c.status = 'secured'
         and c.is_ot = true
         and (exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
         and c.member_id is not null and c.set_id is not null
       group by c.set_id, si.ot_price, sg.grp_created, sg.grp_idtext
      union all
      select coalesce(c.price_override, si.price) as value, array[c.id] as ids, (c.payment_status = 'paid') as is_paid,
             1 as kind_rank, sg.grp_created, sg.grp_idtext,
             1 as sub_order, c.created_at as own_created, c.id::text as own_idtext
        from claims c join sub_items si on si.id = c.sub_item_id
        join set_groups sg on sg.set_id = c.set_id
       where c.username = v_username and si.go_id = p_go_id and c.status = 'secured'
         and c.is_ot = false
         and (exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) and si.order_mode = 'set'
         and c.member_id is not null and c.set_id is not null
    ) u
    order by kind_rank, grp_created, grp_idtext, sub_order, own_created, own_idtext
  loop
    if v_unit.is_paid then
      continue;
    end if;
    if v_spent + v_unit.value <= v_balance + v_loose + 0.001 then
      v_spent := v_spent + v_unit.value;
      v_covered_ids := v_covered_ids || v_unit.ids;
    end if;
  end loop;

  if v_spent <= 0.001 then
    return jsonb_build_object('ok', true, 'spent', 0, 'balance', v_balance,
      'paid_claim_ids', '[]'::jsonb, 'transaction_id', null, 'sources', '[]'::jsonb);
  end if;

  -- Draw only what the loose cash doesn't already cover.
  v_need := greatest(0, v_spent - v_loose);
  if v_need > 0.001 then
    v_tx := 'bal_' || floor(extract(epoch from clock_timestamp()))::bigint
            || '_' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
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
  end if;

  update claims set payment_status = 'paid' where id = any(v_covered_ids);

  return jsonb_build_object('ok', true, 'spent', v_total_drawn, 'balance', v_balance,
    'paid_claim_ids', to_jsonb(v_covered_ids), 'transaction_id', v_tx, 'sources', v_sources);
end $$;


create or replace view go_money
with (security_invoker = on) as
with sec as (
  select si.go_id, si.id as si_id,
         coalesce(c.price_override, si.price, 0) as price, coalesce(si.ot_price, 0) as ot_price, c.price_override as ovr,
         c.username, c.set_id, c.is_ot, coalesce(c.qty, 1) as qty,
         (c.member_id is not null and c.set_id is not null and si.order_mode = 'set'
          and exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))) as set_shaped
  from claims c join sub_items si on si.id = c.sub_item_id
  where c.status = 'secured'
),
per_card as (
  -- claims-based rows: price*qty; set-shaped non-OT slots: flat price (qty ignored, as in the app)
  select go_id, sum(case when set_shaped then price else qty * price end) as amt
  from sec where not (is_ot and set_shaped)
  group by go_id
),
ot_groups as (
  select go_id, si_id, username, set_id, coalesce(max(ovr), max(ot_price)) as ot_price
  from sec where is_ot and set_shaped
  group by go_id, si_id, username, set_id
),
ot_amt as (
  select go_id, sum(ot_price) as amt from ot_groups group by go_id
)
select g.id as go_id,
       coalesce(pc.amt, 0) + coalesce(oa.amt, 0) as expected
from gos g
left join per_card pc on pc.go_id = g.id
left join ot_amt oa on oa.go_id = g.id;
