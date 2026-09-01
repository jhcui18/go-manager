-- 027: securing a claim re-checks the joiner's ledger. Confirm-time allocation
-- only flags claims that are already secured, so paying BEFORE securing left
-- claims flagged unpaid forever ("GO shows paid but my card says unpaid").
-- When a claim flips to secured and the joiner's confirmed payments on that GO
-- cover their full secured value (canonical pricing: set-shaped slots flat,
-- OT groups once at max(override|ot_price), everything else price*qty), all
-- their unpaid secured claims on the GO are flagged paid. Partial coverage
-- changes nothing — flags only flip when the money fully covers.
create or replace function autoflag_paid_on_secure()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_go uuid;
  v_secured numeric := 0;
  v_ot numeric := 0;
  v_paid numeric := 0;
begin
  select go_id into v_go from sub_items where id = new.sub_item_id;
  if v_go is null then return null; end if;

  select coalesce(sum(case
      when (c.member_id is not null and c.set_id is not null and si.order_mode = 'set'
            and exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
                 or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
                 or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set'))))
      then case when c.is_ot then 0 else coalesce(c.price_override, si.price) end
      else coalesce(c.price_override, si.price) * c.qty end), 0)
    into v_secured
  from claims c join sub_items si on si.id = c.sub_item_id
  where c.username = new.username and si.go_id = v_go and c.status = 'secured';

  select coalesce(sum(set_val), 0) into v_ot from (
    select coalesce(max(c.price_override), max(si.ot_price)) as set_val
    from claims c join sub_items si on si.id = c.sub_item_id
    where c.username = new.username and si.go_id = v_go
      and c.status = 'secured' and c.is_ot and si.order_mode = 'set'
      and c.member_id is not null and c.set_id is not null
      and exists (select 1 from gos gg where gg.id = si.go_id and (gg.type = 'photocard'
           or (gg.type = 'album' and coalesce(si.kind::text, gg.type::text) = 'member')
           or (gg.type = 'merch' and coalesce(si.kind::text, gg.type::text) = 'member-set')))
    group by c.set_id) t;
  v_secured := v_secured + v_ot;

  select coalesce(sum(amount), 0) into v_paid from payments
   where username = new.username and status = 'confirmed' and go_id = v_go;

  if v_secured > 0.005 and v_paid >= v_secured - 0.005 then
    update claims c set payment_status = 'paid'
    from sub_items si
    where si.id = c.sub_item_id and si.go_id = v_go
      and c.username = new.username and c.status = 'secured' and c.payment_status = 'unpaid';
  end if;
  return null;
end $$;

drop trigger if exists autoflag_paid on claims;
create trigger autoflag_paid after update of status on claims
  for each row when (new.status = 'secured' and old.status is distinct from new.status)
  execute function autoflag_paid_on_secure();
