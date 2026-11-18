-- 050: apply_balance ignored joiners whose handle was typed with capitals.
-- apply_balance declared v_username text and compared claims.username (citext) = text,
-- which Postgres resolves as text = text: case-sensitive. Usernames are stored lowercase
-- (014), so "Teffyy.vg" matched nothing and the RPC returned ok with spent 0; the site
-- showed "Nothing owed on this GO to apply balance to". The REST reads use citext
-- semantics, so the joiner still saw the credit and the Use balance button.
-- Fix: keep the body as apply_balance_impl, add a thin wrapper that lowercases first.
alter function public.apply_balance(citext, uuid) rename to apply_balance_impl;
create function public.apply_balance(p_username citext, p_go_id uuid)
returns jsonb language sql security definer set search_path to 'public' as $$
  select public.apply_balance_impl(lower(p_username::text)::citext, p_go_id)
$$;
revoke all on function public.apply_balance_impl(citext, uuid) from public, anon, authenticated;
grant execute on function public.apply_balance(citext, uuid) to anon, authenticated;
