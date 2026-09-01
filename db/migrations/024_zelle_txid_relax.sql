-- 024: Zelle has no user-visible transaction id — joiners type their name, and
-- the same-GO duplicate rule (012) then rejects their SECOND legitimate payment
-- to that GO. For Zelle only, the cross-user and same-GO txid checks are
-- skipped; instead a same user+scope+txid+amount submission within 10 minutes
-- is rejected (double-click / duplicate-tab window — the case 021 was built
-- for). Other methods (PayPal/Venmo/Wise) keep the strict rules: their ids are
-- real and unique.
create or replace function submit_payment(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_user text := regexp_replace(trim(p->>'username'), '^@', '');
  v_txid text := nullif(trim(coalesce(p->>'transaction_id','')), '');
  v_method text := lower(coalesce(p->>'method',''));
  v_go uuid := case when p->>'go_id' = 'shop' then null else nullif(p->>'go_id','')::uuid end;
  v_shop boolean := coalesce(p->>'go_id','') = 'shop';
begin
  if v_txid is null then
    return jsonb_build_object('ok', false, 'error', 'txid_required');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(lower(v_user), 1));
  if v_method = 'zelle' then
    if exists (select 1 from payments
               where lower(transaction_id) = lower(v_txid)
                 and username = v_user
                 and (case when v_shop then is_shop else go_id = v_go end)
                 and amount = (p->>'amount')::numeric
                 and created_at > now() - interval '10 minutes') then
      return jsonb_build_object('ok', false, 'error', 'txid_duplicate');
    end if;
  else
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
