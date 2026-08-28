-- 021: double-clicking "I paid" fired two submissions that both passed 012's
-- duplicate check before either inserted (check-then-insert race). Serialize
-- per-user payment submissions with the same advisory-lock pattern
-- apply_balance uses (seed 1 so payments and balance applies don't cross-block)
-- — the second call now waits, then sees the first row and returns
-- txid_duplicate. No unique index: same-txid rows with different amounts exist
-- legitimately from the pre-012 era and stay untouched.
create or replace function submit_payment(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_user text := regexp_replace(trim(p->>'username'), '^@', '');
  v_txid text := nullif(trim(coalesce(p->>'transaction_id','')), '');
  v_go uuid := case when p->>'go_id' = 'shop' then null else nullif(p->>'go_id','')::uuid end;
  v_shop boolean := coalesce(p->>'go_id','') = 'shop';
begin
  if v_txid is null then
    return jsonb_build_object('ok', false, 'error', 'txid_required');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(lower(v_user), 1));
  if exists (select 1 from payments
             where lower(transaction_id) = lower(v_txid)
               and status = 'confirmed'
               and username <> v_user) then
    return jsonb_build_object('ok', false, 'error', 'txid_other_user');
  end if;
  if exists (select 1 from payments
             where lower(transaction_id) = lower(v_txid)
               and username = v_user
               and (case when v_shop then is_shop else go_id = v_go end)) then
    return jsonb_build_object('ok', false, 'error', 'txid_duplicate');
  end if;
  insert into payments (username, go_id, is_shop, amount, method,
                        transaction_id, proof_url, email, status)
  values (v_user, v_go, v_shop,
          (p->>'amount')::numeric,
          p->>'method',
          v_txid,
          nullif(p->>'proof_url',''),
          nullif(p->>'email',''),
          'pending')
  returning id into v_id;
  return jsonb_build_object('ok', true, 'payment_id', v_id);
end $$;
