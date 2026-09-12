-- 030: joiner-side tidy-up on My orders. Two new anon RPCs, same trust model as
-- submit_claim / submit_payment (the joiner is whoever typed the handle):
--   * delete_my_dropped_claims — a joiner deletes their own "Not fulfilled"
--     (status = dropped) claims for good. Dropped claims are never ordered or
--     charged, so only history is lost. Set columns repack via the 029 trigger.
--   * set_my_archived — a joiner hides (or un-hides) their own Shipped claims
--     and shop orders on My orders. Archiving requires fulfillment = Shipped;
--     unarchiving has no state check. Money math ignores the flag entirely;
--     admin views never read it.
alter table claims      add column if not exists archived boolean not null default false;
alter table shop_orders add column if not exists archived boolean not null default false;

create or replace function delete_my_dropped_claims(p_claim_ids uuid[], p_username citext)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user citext := lower(regexp_replace(trim(p_username::text), '^@', ''));
        v_n int;
begin
  if p_claim_ids is null or cardinality(p_claim_ids) = 0 then
    raise exception 'No claims given';
  end if;
  -- Refuse the whole batch unless every id is this joiner's AND dropped.
  select count(*) into v_n from claims
   where id = any(p_claim_ids) and username = v_user and status = 'dropped';
  if v_n <> cardinality(p_claim_ids) then
    raise exception 'Only your own Not-fulfilled claims can be deleted';
  end if;
  delete from claims where id = any(p_claim_ids) and username = v_user and status = 'dropped';
  return jsonb_build_object('ok', true, 'deleted', v_n);
end $$;

create or replace function set_my_archived(p_claim_ids uuid[], p_order_ids uuid[],
                                           p_username citext, p_archived boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user citext := lower(regexp_replace(trim(p_username::text), '^@', ''));
        v_claims uuid[] := coalesce(p_claim_ids, '{}');
        v_orders uuid[] := coalesce(p_order_ids, '{}');
        v_nc int; v_no int;
begin
  if cardinality(v_claims) + cardinality(v_orders) = 0 then
    raise exception 'Nothing to archive';
  end if;
  if p_archived then
    -- Only Shipped items may be archived ('Dispatched' is the legacy spelling).
    select count(*) into v_nc from claims
     where id = any(v_claims) and username = v_user and fulfillment in ('Shipped','Dispatched');
    select count(*) into v_no from shop_orders
     where id = any(v_orders) and username = v_user and fulfillment in ('Shipped','Dispatched');
    if v_nc <> cardinality(v_claims) or v_no <> cardinality(v_orders) then
      raise exception 'Only your own shipped items can be archived';
    end if;
  end if;
  update claims      set archived = p_archived where id = any(v_claims) and username = v_user;
  get diagnostics v_nc = row_count;
  update shop_orders set archived = p_archived where id = any(v_orders) and username = v_user;
  get diagnostics v_no = row_count;
  if v_nc + v_no = 0 then
    raise exception 'Nothing matched';
  end if;
  return jsonb_build_object('ok', true, 'claims', v_nc, 'orders', v_no);
end $$;

revoke execute on function delete_my_dropped_claims(uuid[], citext),
  set_my_archived(uuid[], uuid[], citext, boolean) from public;
grant execute on function delete_my_dropped_claims(uuid[], citext),
  set_my_archived(uuid[], uuid[], citext, boolean) to anon, authenticated;
