# Supabase Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Google Sheets + Apps Script backend with Supabase Postgres — schema, RLS, RPCs, xlsx data migration, and frontend swap — fully built and tested in a sandbox before any cutover.

**Architecture:** Normalized Postgres schema with RLS (anon read + RPC-only writes; single authenticated admin with full CRUD). A `db.*` module inside `index.html` maps normalized rows back into the exact legacy in-memory shapes the render code consumes, so UI code stays untouched. A standalone Python script migrates the `.xlsx` snapshot, replaying the client-side set-spill algorithm once to persist authoritative set assignments.

**Tech Stack:** Supabase (Postgres 15+, PostgREST, supabase-js v2 UMD via CDN, Supabase Auth, Storage), Python 3 (openpyxl + psycopg), Node (parity harness), GitHub Actions (keep-alive).

**Spec:** `docs/superpowers/specs/2026-08-13-supabase-migration-design.md`

## Global Constraints

- Frontend stays a single `index.html` on GitHub Pages, no build step; the only new dependency is the supabase-js v2 UMD CDN `<script>` tag.
- Sandbox project: `https://kkzmvuqfqbonsxebzaii.supabase.co` (already created, empty, MCP-connected). Anon key retrievable via MCP `get_publishable_keys` (the `anon`/legacy JWT key — supabase-js needs a JWT, not the `sb_publishable_` key).
- **Never touch the live Google Sheet, Apps Script, or the deployed site.** Branch `supabase-migration` is never merged to `main` until cutover night (exception: an optional `beta.html` may be added to `main` without touching `index.html`).
- Schema lives in numbered SQL files in `db/migrations/`, committed to git, applied via MCP `apply_migration` (name = file basename without `.sql`).
- UUID PKs (`gen_random_uuid()`), `legacy_id text` on migrated tables, `timestamptz` timestamps, `numeric(10,2)` money, `citext` usernames.
- Anon can never UPDATE/DELETE anything; anon INSERTs happen only through the four anon RPCs, which force status fields server-side.
- Migration script is re-runnable (wipe-and-reload), reads `GO Manager Data.xlsx`, connects only via a `SUPABASE_DB_URL` env var that Jinghan sets in her own shell (Supabase dashboard → Connect → Session pooler URI). Credentials are never committed or pasted into chat.
- Commit after each task. Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## Documented deviations from the spec (with reasons)

1. **`sub_item_kind` keeps the six legacy labels** — `photocard | member | member-set | single | versioned | random` — instead of the spec's collapsed `set | versioned | single | merch`. The render code branches on all six (e.g. `index.html:1129-1133`, `1389-1393`, `2560-2561`); collapsing is lossy and would force a UI rewrite the spec forbids. Postgres enum labels may contain hyphens, so `'member-set'` is legal. "Set mechanics" is derivable: `kind in ('photocard','member','member-set') and order_mode = 'set'`.
2. **The slot-unique index does NOT exclude dropped claims.** The legacy backend's `firstFreeSet` (`go-manager-backend.gs:432-437`) counts dropped claims as occupying their slot, and `buildSetsFromClaims` renders them in slots. Excluding them would let a new claim collide with a dropped one in the same slot and change behavior. Admin frees a slot by deleting the claim, exactly as today.
3. **`buildSetsFromClaims` stays in the frontend as a pure view-builder** rather than retiring. Server authority over set assignment — the spec's actual goal — moves to the `submit_claim` RPC plus the unique index, so the client function can no longer "spill" (collisions are structurally impossible); it just lays out rows. This shrinks the frontend diff and makes the parity harness directly meaningful.
4. **`payments.is_shop boolean`** — the legacy system stores `go_id='shop'` for shop payments (`index.html:1927`, backend `updatePayment`). With `go_id` as a real FK, shop payments store `go_id = null, is_shop = true`; the db layer maps back to `'shop'`.
5. **anon SELECT additionally granted on `payments`, `shop_orders`, and `shipping_request_items`.** The spec's anon list omits them, but §3 requires My Orders (an anon page) to show the user's payments, shop orders, and shipping status. This matches today's exposure; addresses stay hidden (the `shipping_status` view has no address columns).
6. **The `set_payment_due` sheet is not migrated** — it contains only a header row and has zero references in `index.html` or the backend.
7. **`save_go` blocks deleting a sub-item that has claims** (FK `on delete restrict`, per spec §1) instead of silently orphaning claims like the Sheets rewrite does. The admin gets an error naming the sub-item.

## Reference: xlsx export facts (verified against the 2026-08-13 09:53 export)

- Master sheets: `_gos` (18 GOs), `joiners` (7,733 data rows, ~3,207 blank), `payments` (680), `shipping` (1 test row), `listings` (9), `shop_orders` (2), `store_orders` (163), `gc_added` (511), `secured_sets` (239), `closed_subitems` (22), `subitem_deadlines` (22), `subitem_payment_due` (16). `Sheet1` and `set_payment_due` are empty/vestigial.
- Per-GO sub-item sheets are named `go_<go_id>` in Google Sheets, but xlsx export truncates tab names to 31 chars. Three GO pairs share a 31-char prefix (`…run-it--1783953*`, `…run-it--1784161*`, `…this-th-1785873*`), so three sheets got renamed `Sheet2`, `Sheet3`, `Sheet4`. 15 `go_`-named + 3 `SheetN` = 18 sub-item sheets for 18 GOs.
- Sub-item sheet columns: `sub_item_id, name, kind, members (JSON array), versions (JSON array), price, ot_price, min_secure, image_url` (two old sheets lack `image_url`).
- `min_secure < 0` on a sub-item means batch mode with `batch_size = abs(min_secure)` (values seen: -8, -10).
- `assigned_vers` holds `'OT'` (full-set order), a version name, or `'v1+v2'` (random-assigned versions, `+`-joined).
- Legacy enum values seen — claim_status: `pending|secured|dropped`; payment_status: `paid|unpaid`; fulfillment: `Pending|Ordered|On the way` (+ `Ready` on shop orders); payments.status: `pending|confirmed|rejected`; payments.method includes `credit`.

---

### Task 1: Schema migration (`db/migrations/001_schema.sql`)

**Files:**
- Create: `db/migrations/001_schema.sql`

**Interfaces:**
- Produces: all tables/enums below, exactly as named — every later task depends on these names.

- [ ] **Step 1: Write `db/migrations/001_schema.sql`**

```sql
create extension if not exists citext;

create type go_type as enum ('photocard','album','merch');
create type go_status as enum ('open','closed');
create type sub_item_kind as enum ('photocard','member','member-set','single','versioned','random');
create type order_mode as enum ('set','batch');
create type set_status as enum ('open','secured');
create type claim_status as enum ('pending','secured','dropped');
create type payment_status as enum ('unpaid','paid');
create type payment_state as enum ('pending','confirmed','rejected');

create table gos (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  name text not null,
  artist text,
  type go_type not null default 'photocard',
  status go_status not null default 'open',
  deadline timestamptz,
  payment_deadline timestamptz,
  min_secure int not null default 7,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table sub_items (
  id uuid primary key default gen_random_uuid(),
  legacy_id text,
  go_id uuid not null references gos(id) on delete cascade,
  name text not null,
  kind sub_item_kind not null,
  order_mode order_mode not null default 'set',
  batch_size int,
  price numeric(10,2) not null default 0,
  ot_price numeric(10,2) not null default 0,
  min_secure int,
  image_url text,
  position int not null default 0,
  closed boolean not null default false,
  deadline timestamptz,
  pay_due timestamptz,
  created_at timestamptz not null default now(),
  unique (go_id, legacy_id)
);
create index sub_items_go_idx on sub_items(go_id);

create table members (
  id uuid primary key default gen_random_uuid(),
  sub_item_id uuid not null references sub_items(id) on delete cascade,
  name text not null,
  position int not null default 0,
  unique (sub_item_id, name)
);

create table versions (
  id uuid primary key default gen_random_uuid(),
  sub_item_id uuid not null references sub_items(id) on delete cascade,
  name text not null,
  position int not null default 0,
  unique (sub_item_id, name)
);

create table sets (
  id uuid primary key default gen_random_uuid(),
  sub_item_id uuid not null references sub_items(id) on delete cascade,
  set_no int not null,
  status set_status not null default 'open',
  created_at timestamptz not null default now(),
  unique (sub_item_id, set_no)
);

create table claims (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  sub_item_id uuid not null references sub_items(id) on delete restrict,
  username citext not null,
  email text,
  set_id uuid references sets(id),
  member_id uuid references members(id),
  version_id uuid references versions(id),
  is_ot boolean not null default false,
  qty int not null default 1 check (qty > 0),
  assigned_version text,
  status claim_status not null default 'pending',
  payment_status payment_status not null default 'unpaid',
  fulfillment text default 'Pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Dropped claims still occupy their slot (deviation 2) — no status filter.
create unique index claims_slot_unique on claims(set_id, member_id)
  where set_id is not null and member_id is not null;
create index claims_sub_item_idx on claims(sub_item_id);
create index claims_username_idx on claims(username);

create table payments (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  username citext not null,
  go_id uuid references gos(id) on delete set null,
  is_shop boolean not null default false,
  amount numeric(10,2) not null,
  method text,
  transaction_id text,
  proof_url text,
  email text,
  status payment_state not null default 'pending',
  note text,
  created_at timestamptz not null default now()
);
create index payments_username_idx on payments(username);
create index payments_go_idx on payments(go_id);

create table gc_members (
  go_id uuid not null references gos(id) on delete cascade,
  username citext not null,
  primary key (go_id, username)
);

create table shipping_requests (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  username citext not null,
  full_name text,
  address1 text, address2 text, city text, state text, postal text, country text,
  notes text,
  email text,
  ems_fee numeric(10,2),
  dom_fee numeric(10,2),
  total_fee numeric(10,2),
  shipped boolean not null default false,
  created_at timestamptz not null default now()
);
create index shipping_username_idx on shipping_requests(username);

create table shipping_request_items (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references shipping_requests(id) on delete cascade,
  go_id uuid references gos(id) on delete set null,
  description text not null,
  qty int not null default 1
);

create table listings (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  name text not null,
  category text,
  price numeric(10,2) not null default 0,
  image_url text,
  qty int,
  note text,
  status text not null default 'active',
  created_at timestamptz not null default now()
);

create table listing_variants (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references listings(id) on delete cascade,
  name text not null,
  qty int not null default 0
);

create table shop_orders (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  listing_id uuid not null references listings(id) on delete restrict,
  variant_id uuid references listing_variants(id),
  username citext not null,
  email text,
  qty int not null default 1 check (qty > 0),
  unit_price numeric(10,2) not null default 0,
  payment_status payment_status not null default 'unpaid',
  fulfillment text default 'Ready',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index shop_orders_username_idx on shop_orders(username);

create table store_orders (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  go_id uuid references gos(id) on delete set null,
  sub_item_id uuid references sub_items(id) on delete set null,
  store text,
  album_version text,
  qty int not null default 1,
  unit_cost numeric(10,2),
  status text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger gos_updated before update on gos for each row execute function set_updated_at();
create trigger claims_updated before update on claims for each row execute function set_updated_at();
create trigger shop_orders_updated before update on shop_orders for each row execute function set_updated_at();
create trigger store_orders_updated before update on store_orders for each row execute function set_updated_at();
```

- [ ] **Step 2: Apply via MCP** — `mcp__supabase__apply_migration` with `name: "001_schema"` and the file contents.

- [ ] **Step 3: Verify** — `mcp__supabase__list_tables` shows all 14 tables; `mcp__supabase__get_advisors` (type `security`) reports the expected "RLS disabled" warnings (fixed in Task 2) and nothing else unexpected.

- [ ] **Step 4: Commit**

```bash
git add db/migrations/001_schema.sql
git commit -m "db: normalized schema (001)"
```

---

### Task 2: RLS, grants, and the shipping_status view (`db/migrations/002_rls.sql`)

**Files:**
- Create: `db/migrations/002_rls.sql`

**Interfaces:**
- Consumes: Task 1 tables.
- Produces: `shipping_status` view (`id, username, ems_fee, dom_fee, total_fee, shipped, created_at`); policy names as below.

- [ ] **Step 1: Write `db/migrations/002_rls.sql`**

```sql
-- Enable RLS everywhere.
alter table gos enable row level security;
alter table sub_items enable row level security;
alter table members enable row level security;
alter table versions enable row level security;
alter table sets enable row level security;
alter table claims enable row level security;
alter table payments enable row level security;
alter table gc_members enable row level security;
alter table shipping_requests enable row level security;
alter table shipping_request_items enable row level security;
alter table listings enable row level security;
alter table listing_variants enable row level security;
alter table shop_orders enable row level security;
alter table store_orders enable row level security;

-- Admin (single authenticated user): full CRUD on everything.
do $$
declare t text;
begin
  foreach t in array array['gos','sub_items','members','versions','sets','claims',
    'payments','gc_members','shipping_requests','shipping_request_items',
    'listings','listing_variants','shop_orders','store_orders']
  loop
    execute format('create policy admin_all on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- Anon: read-only, and only on non-address tables (deviation 5 adds payments,
-- shop_orders, shipping_request_items for the My Orders page).
do $$
declare t text;
begin
  foreach t in array array['gos','sub_items','members','versions','sets','claims',
    'listings','listing_variants','payments','shop_orders','shipping_request_items']
  loop
    execute format('create policy anon_read on %I for select to anon using (true)', t);
  end loop;
end $$;
-- No anon policy on shipping_requests, gc_members, store_orders → invisible to anon.
-- No anon insert/update/delete policies anywhere → all anon writes go through RPCs.

-- Shipping status WITHOUT addresses (closes the open-addresses hole).
-- security_invoker = false (default): the view runs as its owner (postgres),
-- bypassing shipping_requests RLS but exposing only these columns.
create view shipping_status as
  select id, username, ems_fee, dom_fee, total_fee, shipped, created_at
  from shipping_requests;
grant select on shipping_status to anon, authenticated;
```

- [ ] **Step 2: Apply via MCP** — `apply_migration`, name `002_rls`.

- [ ] **Step 3: Verify with direct SQL** — via `execute_sql`: `select tablename, rowsecurity from pg_tables where schemaname='public'` → all `true`. Then `get_advisors` (security) → no "RLS disabled" errors remain. (Full anon abuse testing is Task 6.)

- [ ] **Step 4: Commit** — `git add db/migrations/002_rls.sql && git commit -m "db: RLS policies + shipping_status view (002)"`

---

### Task 3: Anon RPCs (`db/migrations/003_rpcs_anon.sql`)

**Files:**
- Create: `db/migrations/003_rpcs_anon.sql`

**Interfaces:**
- Produces (called by frontend via `sb.rpc(...)`):
  - `submit_claim(p_claims jsonb) → jsonb` — `p_claims` is an array of `{sub_item_id (uuid), username, email, member (name|null), version (name|null), qty, is_ot (bool), assigned_version (text|null)}`. Returns `{ok, claim_ids:[uuid], set_nums:[int]}` or `{ok:false, error, message}`.
  - `submit_payment(p jsonb) → jsonb` — `{username, go_id (uuid|'shop'|null), amount, method, transaction_id, proof_url, email}` → `{ok, payment_id}`.
  - `submit_shipping(p jsonb) → jsonb` — `{username, full_name, address1, address2, city, state, postal, country, notes, email, items:[{go_id (uuid|null), description, qty}]}` → `{ok, request_id}`.
  - `place_shop_order(p jsonb) → jsonb` — `{listing_id (uuid), variant_id (uuid|null), username, email, qty}` → `{ok, order_id}` or `{ok:false, error:'stock'}`.

- [ ] **Step 1: Write `db/migrations/003_rpcs_anon.sql`**

```sql
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
```

- [ ] **Step 2: Apply via MCP** — `apply_migration`, name `003_rpcs_anon`.

- [ ] **Step 3: Smoke-test with SQL** — via `execute_sql`, insert one throwaway GO + sub-item + two members, then call `submit_claim` three times and assert: (a) two claims for the same member land in sets 1 and 2; (b) an OT pair `[{member:A,is_ot:true},{member:B,is_ot:true}]` gets a fresh set number shared by both; (c) a claim against a `closed` GO returns `error:'closed'`. Delete the throwaway GO afterwards (`delete from gos where legacy_id = 'rpc-smoke'` — cascades).

- [ ] **Step 4: Commit** — `git add db/migrations/003_rpcs_anon.sql && git commit -m "db: anon RPCs — submit_claim/payment/shipping, place_shop_order (003)"`

---

### Task 4: Admin RPCs (`db/migrations/004_rpcs_admin.sql`)

**Files:**
- Create: `db/migrations/004_rpcs_admin.sql`

**Interfaces:**
- Produces (all admin-only; granted to `authenticated` only, plus an `auth.role()` guard):
  - `secure_set(p_sub_item_id uuid, p_set_no int, p_secured boolean) → jsonb`
  - `move_claim(p_claim_id uuid, p_set_no int) → jsonb`
  - `apply_credit(p jsonb)` — `{username, transaction_id, rows:[{go_id (uuid|null), amount, note}], paid_claim_ids:[uuid], unpaid_claim_ids:[uuid]}`
  - `reverse_credit(p jsonb)` — `{transaction_id, paid_claim_ids, unpaid_claim_ids}`
  - `confirm_payment(p jsonb)` — `{payment_id, status, note, amount, username, method, transaction_id, is_shop, paid_ids:[uuid], unpaid_ids:[uuid]}` (paid/unpaid ids are claim ids, or shop-order ids when `is_shop`)
  - `save_go(p jsonb) → jsonb` — create/update a GO **and** rewrite its sub-items/members/versions transactionally. `{go_id (uuid|null), name, artist, type, status, deadline, payment_deadline, min_secure, sub_items:[{id (uuid|null), name, kind, order_mode, batch_size, price, ot_price, min_secure, image_url, position, members:[text], versions:[text]}]}` → `{ok, go_id, sub_item_ids:[uuid]}` (ids in payload order).

- [ ] **Step 1: Write `db/migrations/004_rpcs_admin.sql`**

```sql
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
```

- [ ] **Step 2: Apply via MCP** — `apply_migration`, name `004_rpcs_admin`.

- [ ] **Step 3: Smoke-test with SQL** — via `execute_sql` (runs as postgres, so `assert_admin()` raises; test with `set local role authenticated; set local request.jwt.claims = '{"role":"authenticated"}';` inside a transaction): call `save_go` to create a GO with 2 sub-items, verify `sub_item_ids` come back and members rows exist; call `secure_set` and verify set + claim statuses; clean up.

- [ ] **Step 4: Commit** — `git add db/migrations/004_rpcs_admin.sql && git commit -m "db: admin RPCs — save_go, secure_set, credit, confirm_payment (004)"`

---

### Task 5: Storage bucket for item images (`db/migrations/005_storage.sql`)

**Files:**
- Create: `db/migrations/005_storage.sql`

- [ ] **Step 1: Write `db/migrations/005_storage.sql`**

```sql
insert into storage.buckets (id, name, public)
values ('item-images', 'item-images', true)
on conflict (id) do nothing;

create policy "admin upload item-images" on storage.objects
  for insert to authenticated with check (bucket_id = 'item-images');
create policy "admin update item-images" on storage.objects
  for update to authenticated using (bucket_id = 'item-images');
create policy "admin delete item-images" on storage.objects
  for delete to authenticated using (bucket_id = 'item-images');
-- Public read comes from the bucket's public flag (served via /storage/v1/object/public/).
```

- [ ] **Step 2: Apply via MCP** — `apply_migration`, name `005_storage`. Verify with `execute_sql`: `select id, public from storage.buckets` → `item-images | true`.

- [ ] **Step 3: Commit** — `git add db/migrations/005_storage.sql && git commit -m "db: public item-images bucket, admin-only writes (005)"`

---

### Task 6: RLS verification script (`db/test_rls.sh`)

Spec success criterion 4 — verified with direct API calls, not the UI.

**Files:**
- Create: `db/test_rls.sh`

- [ ] **Step 1: Write `db/test_rls.sh`**

```bash
#!/usr/bin/env bash
# Verifies anon-key boundaries with raw REST calls. Requires: SUPABASE_URL, SUPABASE_ANON_KEY.
set -u
BASE="$SUPABASE_URL/rest/v1"
H=(-H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY")
pass=0; fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1";
  else fail=$((fail+1)); echo "FAIL  $1 (expected $2, got $3)"; fi
}

# Reads that must work (HTTP 200)
for t in gos sub_items members versions sets claims listings listing_variants \
         payments shop_orders shipping_request_items shipping_status; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" "$BASE/$t?select=*&limit=1")
  check "anon can read $t" 200 "$code"
done

# Tables that must be invisible to anon: RLS returns 200 with an EMPTY array.
for t in shipping_requests gc_members store_orders; do
  body=$(curl -s "${H[@]}" "$BASE/$t?select=*&limit=1")
  check "anon sees no rows in $t" "[]" "$body"
done

# The view must not expose address columns (selecting one must 400).
code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" "$BASE/shipping_status?select=address1&limit=1")
check "shipping_status hides addresses" 400 "$code"

# Writes that must all be denied (401/403/404 — anything but 2xx).
code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$BASE/claims" \
  -H "Content-Type: application/json" -d '{"username":"hacker","qty":1}')
check "anon cannot INSERT claims directly" 0 "$( [ "${code:0:1}" = 2 ] && echo 2xx || echo 0 )"
code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X PATCH \
  "$BASE/claims?limit=1" -H "Content-Type: application/json" -d '{"payment_status":"paid"}')
check "anon cannot UPDATE claims" 0 "$( [ "${code:0:1}" = 2 ] && echo 2xx || echo 0 )"
code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X DELETE "$BASE/claims?username=eq.nobody")
check "anon cannot DELETE claims" 0 "$( [ "${code:0:1}" = 2 ] && echo 2xx || echo 0 )"
code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X PATCH \
  "$BASE/gos?limit=1" -H "Content-Type: application/json" -d '{"status":"closed"}')
check "anon cannot UPDATE gos" 0 "$( [ "${code:0:1}" = 2 ] && echo 2xx || echo 0 )"

# Admin RPCs must be denied to anon.
for fn in secure_set move_claim apply_credit reverse_credit confirm_payment save_go; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$BASE/rpc/$fn" \
    -H "Content-Type: application/json" -d '{}')
  check "anon cannot call $fn" 0 "$( [ "${code:0:1}" = 2 ] && echo 2xx || echo 0 )"
done

echo; echo "$pass passed, $fail failed"; exit $([ $fail -eq 0 ] && echo 0 || echo 1)
```

Note on PATCH/DELETE: PostgREST rejects RLS-blocked writes with 401/403, or "succeeds" matching 0 rows (204 with no effect). If a 204 shows up, tighten the check to assert the row count is 0 (`Prefer: count=exact` + `Content-Range: */0`) rather than treating 2xx as pass — a 2xx that changed nothing is still a pass; a 2xx that changed a row is the failure. Verify actual behavior when running and adjust the two PATCH/DELETE checks accordingly.

- [ ] **Step 2: Run it** — `chmod +x db/test_rls.sh && SUPABASE_URL=https://kkzmvuqfqbonsxebzaii.supabase.co SUPABASE_ANON_KEY=<anon key from MCP get_publishable_keys> ./db/test_rls.sh`. Expected: 0 failed. (Insert one dummy shipping_request via `execute_sql` first so the "empty array" checks prove filtering, not table emptiness; delete it after.)

- [ ] **Step 3: Commit** — `git add db/test_rls.sh && git commit -m "db: anon RLS boundary verification script"`

---

### Task 7: Migration script — transforms + spill replay + quality report (`db/migrate_from_xlsx.py`, dry-run)

**Files:**
- Create: `db/migrate_from_xlsx.py`
- Create: `db/test_spill_replay.py`

**Interfaces:**
- Produces: `python3 db/migrate_from_xlsx.py --dry-run` → parses the xlsx, resolves sheets, computes all rows + set assignments, prints the quality report and per-table intended counts, writes nothing. `build_sets_from_claims(claims, members) -> dict[claim_id, set_no]` (used by tests).
- Consumes: `GO Manager Data.xlsx` in the repo root.

- [ ] **Step 1: Write the spill-replay port and its test first.** In `db/migrate_from_xlsx.py`:

```python
def parse_int(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return 0

def build_sets_from_claims(claims, members):
    """Exact port of index.html buildSetsFromClaims placement logic (lines 5189-5245):
    fairness order by (created_at, claim_id); pass 1 groups OT claims by
    (username, declared set) into atomic fresh-numbered sets; pass 2 spills
    individual claims to the first non-OT set where their member slot is free.
    Returns {claim_id: set_no}. `members` is unused for placement (slots are a
    dict) but kept for signature parity / future validation."""
    ordered = sorted(claims, key=lambda c: (c.get('created_at') or '', str(c.get('claim_id'))))
    assignment = {}
    sets_by_num = {}   # set_no -> {member_name: claim_id}
    ot_set_nums = set()

    ot_groups = {}     # (username, declared) -> [claims], insertion-ordered
    for c in ordered:
        if c.get('assigned_vers') != 'OT':
            continue
        key = (c.get('username'), parse_int(c.get('set_num')) or 1)
        ot_groups.setdefault(key, []).append(c)
    for (_, declared), group in ot_groups.items():
        n = declared
        while n in sets_by_num:      # never reuse a number already owned by another set
            n += 1
        sets_by_num[n] = {}
        ot_set_nums.add(n)
        for c in group:
            sets_by_num[n][c.get('member_or_version')] = c['claim_id']
            assignment[c['claim_id']] = n

    def smallest_non_ot():
        n = 1
        while n in sets_by_num or n in ot_set_nums:
            n += 1
        return n

    for c in ordered:
        if c.get('assigned_vers') == 'OT':
            continue
        member = c.get('member_or_version')
        declared = parse_int(c.get('set_num')) or 1
        higher = sorted(x for x in sets_by_num if x > declared and x not in ot_set_nums)
        placed = False
        for n in [declared, *higher]:
            if n in ot_set_nums:
                continue
            slots = sets_by_num.setdefault(n, {})
            if member not in slots:
                slots[member] = c['claim_id']
                assignment[c['claim_id']] = n
                placed = True
                break
        if not placed:
            n = smallest_non_ot()
            sets_by_num.setdefault(n, {})[member] = c['claim_id']
            assignment[c['claim_id']] = n
    return assignment
```

And `db/test_spill_replay.py`:

```python
from migrate_from_xlsx import build_sets_from_claims

def c(cid, user, member, set_num, created, ot=False):
    return {'claim_id': cid, 'username': user, 'member_or_version': member,
            'set_num': set_num, 'created_at': created,
            'assigned_vers': 'OT' if ot else ''}

MEMBERS = ['A', 'B', 'C']

def test_simple_placement():
    a = build_sets_from_claims([c('1', 'u1', 'A', 1, 't1')], MEMBERS)
    assert a == {'1': 1}

def test_collision_spills_to_next_set():
    a = build_sets_from_claims(
        [c('1', 'u1', 'A', 1, 't1'), c('2', 'u2', 'A', 1, 't2')], MEMBERS)
    assert a == {'1': 1, '2': 2}

def test_earliest_wins_regardless_of_row_order():
    a = build_sets_from_claims(
        [c('2', 'u2', 'A', 1, 't2'), c('1', 'u1', 'A', 1, 't1')], MEMBERS)
    assert a == {'1': 1, '2': 2}

def test_ot_set_is_atomic_and_reserved():
    claims = [c('o1', 'u1', 'A', 1, 't1', ot=True), c('o2', 'u1', 'B', 1, 't1', ot=True),
              c('i1', 'u2', 'C', 1, 't2')]
    a = build_sets_from_claims(claims, MEMBERS)
    assert a['o1'] == a['o2'] == 1
    assert a['i1'] == 2          # individual never enters the OT set

def test_two_ot_full_sets_get_distinct_numbers():
    claims = [c('o1', 'u1', 'A', 1, 't1', ot=True),
              c('o2', 'u1', 'A', 2, 't1', ot=True)]   # second full set, declared 2
    a = build_sets_from_claims(claims, MEMBERS)
    assert a['o1'] != a['o2']

def test_tiebreak_by_claim_id_when_same_timestamp():
    a = build_sets_from_claims(
        [c('b', 'u2', 'A', 1, 't1'), c('a', 'u1', 'A', 1, 't1')], MEMBERS)
    assert a == {'a': 1, 'b': 2}
```

- [ ] **Step 2: Run the tests** — `cd db && python3 -m pytest test_spill_replay.py -v`. Expected: all 6 pass. (If pytest is missing: `pip3 install pytest openpyxl psycopg[binary]`.)

- [ ] **Step 3: Write the rest of the dry-run pipeline** in `db/migrate_from_xlsx.py`, below the replay function. Full structure — every piece listed here must be real code, none stubbed:

```python
#!/usr/bin/env python3
"""Wipe-and-reload migration: GO Manager Data.xlsx -> Supabase Postgres.
Usage:
  python3 db/migrate_from_xlsx.py --dry-run     # parse + report only
  SUPABASE_DB_URL=postgresql://... python3 db/migrate_from_xlsx.py  # full load
Never touches Google Sheets or the live site."""
import argparse, json, os, re, sys, uuid
from collections import defaultdict
from datetime import datetime, timezone
from openpyxl import load_workbook

XLSX = os.path.join(os.path.dirname(__file__), '..', 'GO Manager Data.xlsx')
SET_KINDS = {'photocard', 'member', 'member-set'}
report = defaultdict(list)     # category -> [detail rows]

def rows_as_dicts(ws):
    header = [c.value for c in ws[1]]
    out = []
    for r in ws.iter_rows(min_row=2, values_only=True):
        d = dict(zip(header, r))
        if any(v not in (None, '') for v in d.values()):
            out.append(d)
    return out

def to_ts(v, ctx=''):
    if v in (None, ''):
        return None
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    s = str(v).strip()
    try:
        return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except ValueError:
        report['unparseable_dates'].append(f'{ctx}: {s!r}')
        return None

def norm_user(v):
    return re.sub(r'^@', '', str(v or '').strip())

def parse_members(val):
    """Mirror of index.html parseMembers: JSON array first, then newline/comma split."""
    if val in (None, ''):
        return []
    s = str(val).strip()
    if s in ('', '[]', '""'):
        return []
    try:
        parsed = json.loads(s)
        if isinstance(parsed, list):
            return [str(x).strip() for x in parsed if str(x).strip()]
    except (json.JSONDecodeError, ValueError):
        pass
    sep = '\n' if '\n' in s else ','
    return [x.strip() for x in s.split(sep) if x.strip()]

def parse_money(v):
    try:
        return round(float(v), 2)
    except (TypeError, ValueError):
        return 0.0

def artist_from_name(name):
    return name.split(' - ')[0].strip() if name and ' - ' in name else None

def resolve_go_sheets(wb, gos, joiners):
    """Map go_id -> worksheet. Google's xlsx export truncates tab names to 31
    chars; colliding names get renamed 'SheetN'. Match uniquely-truncated names
    directly; disambiguate the rest by intersecting each sheet's sub_item_ids
    with each GO's claimed sub_item_ids from the joiners sheet."""
    si_sheets = {ws.title: ws for ws in wb.worksheets if ws['A1'].value == 'sub_item_id'}
    sheet_siids = {t: {r['sub_item_id'] for r in rows_as_dicts(ws) if r.get('sub_item_id')}
                   for t, ws in si_sheets.items()}
    claims_siids = defaultdict(set)
    for c in joiners:
        if c.get('go_id') and c.get('sub_item_id'):
            claims_siids[c['go_id']].add(c['sub_item_id'])

    by_trunc = defaultdict(list)
    for g in gos:
        by_trunc[('go_' + g['go_id'])[:31]].append(g['go_id'])

    mapping, taken = {}, set()
    ambiguous = []
    for trunc, ids in by_trunc.items():
        if len(ids) == 1 and trunc in si_sheets:
            mapping[ids[0]] = trunc
            taken.add(trunc)
        else:
            ambiguous.extend(ids)
    remaining_sheets = [t for t in si_sheets if t not in taken]
    for gid in list(ambiguous):
        want = claims_siids.get(gid, set())
        hits = [t for t in remaining_sheets if t not in taken and sheet_siids[t] & want]
        if len(hits) == 1:
            mapping[gid] = hits[0]
            taken.add(hits[0])
            ambiguous.remove(gid)
    # Elimination for claimless GOs: if exactly one GO and one sheet remain in a
    # truncation group, pair them.
    for gid in list(ambiguous):
        left = [t for t in remaining_sheets if t not in taken]
        if len([g for g in ambiguous]) == 1 and len(left) == 1:
            mapping[gid] = left[0]
            taken.add(left[0])
            ambiguous.remove(gid)
    for gid in ambiguous:
        report['unresolved_go_sheets'].append(gid)
    for t in si_sheets:
        if t not in taken:
            report['unmatched_subitem_sheets'].append(t)
    return {gid: si_sheets[t] for gid, t in mapping.items()}

def build_dataset(wb):
    """Everything the loader needs, as plain dicts keyed by legacy ids.
    Returns dict with keys: gos, sub_items, members, versions, sets, claims,
    payments, gc, shipping, shipping_items, listings, variants, shop_orders,
    store_orders. All FK references are legacy ids resolved to uuids at load."""
    gos = rows_as_dicts(wb['_gos'])
    joiners = [c for c in rows_as_dicts(wb['joiners']) if c.get('claim_id')]
    go_sheets = resolve_go_sheets(wb, gos, joiners)
    flags_closed = {(r['go_id'], r['sub_item_id']) for r in rows_as_dicts(wb['closed_subitems'])}
    flags_dead = {(r['go_id'], r['sub_item_id']): r['deadline'] for r in rows_as_dicts(wb['subitem_deadlines'])}
    flags_pay = {(r['go_id'], r['sub_item_id']): r['due_date'] for r in rows_as_dicts(wb['subitem_payment_due'])}
    secured = {(r['go_id'], r['sub_item_id'], parse_int(r['set_num']))
               for r in rows_as_dicts(wb['secured_sets'])}
    ds = {'gos': [], 'sub_items': [], 'members': [], 'versions': [], 'sets': [],
          'claims': [], 'payments': [], 'gc': [], 'shipping': [], 'shipping_items': [],
          'listings': [], 'variants': [], 'shop_orders': [], 'store_orders': []}

    claims_by_go = defaultdict(list)
    for c in joiners:
        claims_by_go[c.get('go_id')].append(c)

    known_go_ids = {g['go_id'] for g in gos}
    for c in joiners:
        if c.get('go_id') not in known_go_ids:
            report['orphan_claims_unknown_go'].append(c['claim_id'])

    for g in gos:
        gid = g['go_id']
        ds['gos'].append({
            'legacy_id': gid, 'name': g['name'], 'artist': artist_from_name(g['name']),
            'type': g.get('type') or 'photocard', 'status': g.get('status') or 'open',
            'deadline': to_ts(g.get('deadline'), f'go {gid} deadline'),
            'payment_deadline': to_ts(g.get('payment_deadline'), f'go {gid} pay_deadline'),
            'min_secure': parse_int(g.get('min_secure')) or 7,
            'created_at': to_ts(g.get('created_at'), f'go {gid} created'),
        })
        ws = go_sheets.get(gid)
        if ws is None:
            report['gos_without_subitem_sheet'].append(gid)
            continue
        si_rows = [r for r in rows_as_dicts(ws) if r.get('sub_item_id')]
        si_ids = {r['sub_item_id'] for r in si_rows}

        # Frontend orphan-remap (index.html:5014-5032): claims pointing at a
        # sub_item_id that no longer exists get remapped to the single
        # empty-members sub-item, if exactly one exists.
        orphans = [c for c in claims_by_go[gid] if c['sub_item_id'] not in si_ids]
        if orphans:
            empties = [r for r in si_rows if not parse_members(r.get('members'))]
            if len(empties) == 1:
                for c in orphans:
                    c['sub_item_id'] = empties[0]['sub_item_id']
                report['remapped_orphan_claims'].append(
                    f"{gid}: {len(orphans)} claims -> {empties[0]['sub_item_id']}")
            else:
                report['orphan_claims_no_target'].extend(c['claim_id'] for c in orphans)

        for pos, r in enumerate(si_rows):
            siid = r['sub_item_id']
            members = parse_members(r.get('members'))
            if not members:
                # Frontend fallback (index.html:5040-5044): reconstruct from claims.
                seen = {c['member_or_version'] for c in claims_by_go[gid]
                        if c['sub_item_id'] == siid and c.get('member_or_version')}
                members = sorted(seen)
                if members:
                    report['members_reconstructed_from_claims'].append(f'{gid}/{siid}')
            versions = parse_members(r.get('versions'))
            ms = parse_int(r.get('min_secure')) or 7
            kind = r.get('kind') or 'random'
            if kind not in ('photocard', 'member', 'member-set', 'single', 'versioned', 'random'):
                report['unknown_kinds'].append(f'{gid}/{siid}: {kind!r}')
                kind = 'random'
            ds['sub_items'].append({
                'legacy_id': siid, 'go': gid, 'name': r.get('name') or '',
                'kind': kind,
                'order_mode': 'batch' if ms < 0 else 'set',
                'batch_size': abs(ms) if ms < 0 else None,
                'price': parse_money(r.get('price')), 'ot_price': parse_money(r.get('ot_price')),
                'min_secure': ms if ms >= 0 else None,
                'image_url': r.get('image_url') or None, 'position': pos,
                'closed': (gid, siid) in flags_closed,
                'deadline': to_ts(flags_dead.get((gid, siid)), f'{siid} deadline'),
                'pay_due': to_ts(flags_pay.get((gid, siid)), f'{siid} pay_due'),
            })
            for i, m in enumerate(members):
                ds['members'].append({'si': (gid, siid), 'name': m, 'position': i})
            for i, v in enumerate(versions):
                ds['versions'].append({'si': (gid, siid), 'name': v, 'position': i})

            # Set replay for set-mechanic sub-items.
            si_claims = [c for c in claims_by_go[gid] if c['sub_item_id'] == siid]
            member_set = set(members)
            if kind in SET_KINDS and ms >= 0:
                placeable = [c for c in si_claims if c.get('member_or_version')]
                for c in placeable:
                    if c['member_or_version'] not in member_set and c.get('assigned_vers') != 'OT':
                        report['unknown_member_names'].append(
                            f"{c['claim_id']}: {c['member_or_version']!r} not in {gid}/{siid}")
                assignment = build_sets_from_claims(
                    [{'claim_id': c['claim_id'], 'username': norm_user(c.get('username')),
                      'member_or_version': c['member_or_version'],
                      'set_num': c.get('set_num'),
                      'created_at': str(c.get('created_at') or ''),
                      'assigned_vers': c.get('assigned_vers') or ''}
                     for c in placeable], members)
                for n in sorted(set(assignment.values())):
                    ds['sets'].append({'si': (gid, siid), 'set_no': n,
                                       'status': 'secured' if (gid, siid, n) in secured else 'open'})
                for c in si_claims:
                    c['_set_no'] = assignment.get(c['claim_id'])
                    if c.get('member_or_version') and c['claim_id'] not in assignment:
                        report['set_claims_left_unplaced'].append(c['claim_id'])

    known_si = {(s['go'], s['legacy_id']): s for s in ds['sub_items']}
    member_names = {(m['si'], m['name']) for m in ds['members']}
    version_names = {(v['si'], v['name']) for v in ds['versions']}
    for c in joiners:
        key = (c.get('go_id'), c.get('sub_item_id'))
        si = known_si.get(key)
        if si is None:
            continue    # already reported as orphan
        mv = c.get('member_or_version') or ''
        is_set_claim = si['kind'] in SET_KINDS and si['order_mode'] == 'set' and c.get('_set_no')
        member_ref = key if (mv and (key, mv) in member_names) else None
        version_ref = key if (mv and (key, mv) in version_names) else None
        ds['claims'].append({
            'legacy_id': c['claim_id'], 'si': key,
            'username': norm_user(c.get('username')),
            'email': c.get('email') or None,
            'set_no': c.get('_set_no') if is_set_claim else None,
            'member': mv if member_ref else None,
            'version': mv if (version_ref and not member_ref) else None,
            'is_ot': c.get('assigned_vers') == 'OT',
            'qty': max(parse_int(c.get('qty')), 1),
            'assigned_version': (c.get('assigned_vers') or None)
                                 if c.get('assigned_vers') != 'OT' else None,
            'status': c.get('claim_status') or 'pending',
            'payment_status': c.get('payment_status') or 'unpaid',
            'fulfillment': c.get('fulfillment') or 'Pending',
            'created_at': to_ts(c.get('created_at'), f"claim {c['claim_id']}"),
            'updated_at': to_ts(c.get('updated_at'), f"claim {c['claim_id']}"),
        })

    for p in rows_as_dicts(wb['payments']):
        if not p.get('payment_id'):
            continue
        ds['payments'].append({
            'legacy_id': p['payment_id'], 'username': norm_user(p.get('username')),
            'go': p.get('go_id') if p.get('go_id') in known_go_ids else None,
            'is_shop': p.get('go_id') == 'shop',
            'amount': parse_money(p.get('amount')), 'method': p.get('method'),
            'transaction_id': p.get('transaction_id') or None,
            'proof_url': p.get('proof_url') or None, 'email': p.get('email') or None,
            'status': p.get('status') or 'pending', 'note': p.get('note') or None,
            'created_at': to_ts(p.get('created_at'), f"payment {p['payment_id']}"),
        })
        if p.get('go_id') and p['go_id'] not in known_go_ids and p['go_id'] != 'shop':
            report['payments_unknown_go'].append(f"{p['payment_id']}: {p['go_id']}")

    for r in rows_as_dicts(wb['gc_added']):
        if r.get('go_id') in known_go_ids and r.get('username'):
            ds['gc'].append({'go': r['go_id'], 'username': norm_user(r['username'])})

    for s in rows_as_dicts(wb['shipping']):
        if not s.get('request_id'):
            continue
        ds['shipping'].append({
            'legacy_id': s['request_id'], 'username': norm_user(s.get('username')),
            'full_name': s.get('full_name'), 'address1': s.get('address1'),
            'address2': s.get('address2') or None, 'city': s.get('city'),
            'state': s.get('state'), 'postal': s.get('postal'), 'country': s.get('country'),
            'notes': s.get('notes') or None, 'email': s.get('email') or None,
            'ems_fee': parse_money(s['ems_fee']) if s.get('ems_fee') not in (None, '') else None,
            'dom_fee': parse_money(s['dom_fee']) if s.get('dom_fee') not in (None, '') else None,
            'total_fee': parse_money(s['total_fee']) if s.get('total_fee') not in (None, '') else None,
            'shipped': bool(s.get('shipped')),
            'created_at': to_ts(s.get('created_at'), f"shipping {s['request_id']}"),
        })
        try:
            items = json.loads(s.get('items') or '[]')
        except (json.JSONDecodeError, ValueError):
            items = []
            report['bad_shipping_items_json'].append(s['request_id'])
        for it in items:
            ds['shipping_items'].append({'request': s['request_id'], 'go': None,
                                         'description': it.get('label') or '', 'qty': 1})

    for l in rows_as_dicts(wb['listings']):
        if not l.get('listing_id'):
            continue
        try:
            variants = json.loads(l.get('variants') or 'null') or []
        except (json.JSONDecodeError, ValueError):
            variants = []
            report['bad_variants_json'].append(l['listing_id'])
        ds['listings'].append({
            'legacy_id': l['listing_id'], 'name': l.get('name') or '',
            'category': l.get('category'), 'price': parse_money(l.get('price')),
            'image_url': l.get('image_url') or None,
            'qty': parse_int(l.get('qty')) if not variants else None,
            'note': l.get('note') or None, 'status': l.get('status') or 'active',
            'created_at': to_ts(l.get('created_at'), f"listing {l['listing_id']}"),
        })
        for v in variants:
            ds['variants'].append({'listing': l['listing_id'], 'name': v.get('name'),
                                   'qty': parse_int(v.get('qty'))})

    known_listings = {l['legacy_id'] for l in ds['listings']}
    variant_names = {(v['listing'], v['name']) for v in ds['variants']}
    for o in rows_as_dicts(wb['shop_orders']):
        if not o.get('order_id'):
            continue
        if o.get('listing_id') not in known_listings:
            report['shop_orders_unknown_listing'].append(o['order_id'])
            continue
        ds['shop_orders'].append({
            'legacy_id': o['order_id'], 'listing': o['listing_id'],
            'variant': (o['listing_id'], o['variant'])
                       if o.get('variant') and (o['listing_id'], o['variant']) in variant_names
                       else None,
            'username': norm_user(o.get('username')), 'email': o.get('email') or None,
            'qty': max(parse_int(o.get('qty')), 1), 'unit_price': parse_money(o.get('unit_price')),
            'payment_status': o.get('payment_status') or 'unpaid',
            'fulfillment': o.get('fulfillment') or 'Ready',
            'created_at': to_ts(o.get('created_at'), f"shop {o['order_id']}"),
            'updated_at': to_ts(o.get('updated_at'), f"shop {o['order_id']}"),
        })

    for o in rows_as_dicts(wb['store_orders']):
        if not o.get('order_id'):
            continue
        si_key = (o.get('go_id'), o.get('sub_item_id'))
        ds['store_orders'].append({
            'legacy_id': o['order_id'],
            'go': o.get('go_id') if o.get('go_id') in known_go_ids else None,
            'si': si_key if si_key in known_si else None,
            'store': o.get('store'), 'album_version': o.get('album_version') or None,
            'qty': max(parse_int(o.get('qty')), 1),
            'unit_cost': parse_money(o.get('unit_cost')) if o.get('unit_cost') not in (None, '') else None,
            'status': o.get('status'), 'notes': o.get('notes') or None,
            'created_at': to_ts(o.get('created_at'), f"store {o['order_id']}"),
            'updated_at': to_ts(o.get('updated_at'), f"store {o['order_id']}"),
        })
    return ds

def print_report(ds):
    print('=== intended row counts ===')
    for k in ds:
        print(f'  {k:16s} {len(ds[k])}')
    print('=== data-quality report ===')
    if not report:
        print('  clean — no issues found')
    for cat, items in sorted(report.items()):
        print(f'  {cat} ({len(items)}):')
        for it in items[:20]:
            print(f'    - {it}')
        if len(items) > 20:
            print(f'    … and {len(items) - 20} more')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()
    wb = load_workbook(XLSX)
    ds = build_dataset(wb)
    print_report(ds)
    if args.dry_run:
        return
    load(ds)   # Task 8

if __name__ == '__main__':
    main()
```

- [ ] **Step 4: Run the dry run** — `python3 db/migrate_from_xlsx.py --dry-run`. Expected: all 18 GOs resolve to a sheet (`unresolved_go_sheets` and `unmatched_subitem_sheets` empty); counts in the vicinity of: gos 18, sub_items ~190, claims ~4,520, payments ~680, gc ~511, store_orders ~163. Every non-empty report category gets eyeballed; anything surprising goes to Jinghan for a fix/skip/keep decision before Task 8.

- [ ] **Step 5: Commit** — `git add db/migrate_from_xlsx.py db/test_spill_replay.py && git commit -m "db: xlsx migration transforms + set-spill replay (dry-run)"`

---

### Task 8: Migration script — DB load + validation (`load()` in `db/migrate_from_xlsx.py`)

**Files:**
- Modify: `db/migrate_from_xlsx.py` (add `load()`)

**Interfaces:**
- Consumes: `ds` dict from `build_dataset`; `SUPABASE_DB_URL` env var (Session-pooler URI from the Supabase dashboard — Jinghan sets it in her shell, it is never committed).
- Produces: fully loaded sandbox DB; printed loaded-vs-intended count check.

- [ ] **Step 1: Add `load(ds)`**

```python
def load(ds):
    import psycopg
    dsn = os.environ.get('SUPABASE_DB_URL')
    if not dsn:
        sys.exit('Set SUPABASE_DB_URL (Supabase dashboard -> Connect -> Session pooler URI).')
    with psycopg.connect(dsn) as conn, conn.cursor() as cur:
        cur.execute("""truncate gos, sub_items, members, versions, sets, claims,
            payments, gc_members, shipping_requests, shipping_request_items,
            listings, listing_variants, shop_orders, store_orders cascade""")

        go_ids, si_ids, member_ids, version_ids = {}, {}, {}, {}
        set_ids, listing_ids, variant_ids, ship_ids = {}, {}, {}, {}

        for g in ds['gos']:
            cur.execute("""insert into gos (legacy_id, name, artist, type, status,
                deadline, payment_deadline, min_secure, created_at)
                values (%s,%s,%s,%s,%s,%s,%s,%s,coalesce(%s, now())) returning id""",
                (g['legacy_id'], g['name'], g['artist'], g['type'], g['status'],
                 g['deadline'], g['payment_deadline'], g['min_secure'], g['created_at']))
            go_ids[g['legacy_id']] = cur.fetchone()[0]

        for s in ds['sub_items']:
            cur.execute("""insert into sub_items (legacy_id, go_id, name, kind,
                order_mode, batch_size, price, ot_price, min_secure, image_url,
                position, closed, deadline, pay_due)
                values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) returning id""",
                (s['legacy_id'], go_ids[s['go']], s['name'], s['kind'], s['order_mode'],
                 s['batch_size'], s['price'], s['ot_price'], s['min_secure'],
                 s['image_url'], s['position'], s['closed'], s['deadline'], s['pay_due']))
            si_ids[(s['go'], s['legacy_id'])] = cur.fetchone()[0]

        for m in ds['members']:
            cur.execute("insert into members (sub_item_id, name, position) values (%s,%s,%s) returning id",
                        (si_ids[m['si']], m['name'], m['position']))
            member_ids[(m['si'], m['name'])] = cur.fetchone()[0]
        for v in ds['versions']:
            cur.execute("insert into versions (sub_item_id, name, position) values (%s,%s,%s) returning id",
                        (si_ids[v['si']], v['name'], v['position']))
            version_ids[(v['si'], v['name'])] = cur.fetchone()[0]
        for s in ds['sets']:
            cur.execute("insert into sets (sub_item_id, set_no, status) values (%s,%s,%s) returning id",
                        (si_ids[s['si']], s['set_no'], s['status']))
            set_ids[(s['si'], s['set_no'])] = cur.fetchone()[0]

        for c in ds['claims']:
            cur.execute("""insert into claims (legacy_id, sub_item_id, username, email,
                set_id, member_id, version_id, is_ot, qty, assigned_version,
                status, payment_status, fulfillment, created_at, updated_at)
                values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,
                        coalesce(%s, now()), coalesce(%s, now()))""",
                (c['legacy_id'], si_ids[c['si']], c['username'], c['email'],
                 set_ids.get((c['si'], c['set_no'])) if c['set_no'] else None,
                 member_ids.get((c['si'], c['member'])) if c['member'] else None,
                 version_ids.get((c['si'], c['version'])) if c['version'] else None,
                 c['is_ot'], c['qty'], c['assigned_version'], c['status'],
                 c['payment_status'], c['fulfillment'], c['created_at'], c['updated_at']))

        for p in ds['payments']:
            cur.execute("""insert into payments (legacy_id, username, go_id, is_shop,
                amount, method, transaction_id, proof_url, email, status, note, created_at)
                values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,coalesce(%s, now()))""",
                (p['legacy_id'], p['username'], go_ids.get(p['go']), p['is_shop'],
                 p['amount'], p['method'], p['transaction_id'], p['proof_url'],
                 p['email'], p['status'], p['note'], p['created_at']))

        for r in ds['gc']:
            cur.execute("insert into gc_members (go_id, username) values (%s,%s) on conflict do nothing",
                        (go_ids[r['go']], r['username']))

        for s in ds['shipping']:
            cur.execute("""insert into shipping_requests (legacy_id, username, full_name,
                address1, address2, city, state, postal, country, notes, email,
                ems_fee, dom_fee, total_fee, shipped, created_at)
                values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,coalesce(%s, now()))
                returning id""",
                (s['legacy_id'], s['username'], s['full_name'], s['address1'], s['address2'],
                 s['city'], s['state'], s['postal'], s['country'], s['notes'], s['email'],
                 s['ems_fee'], s['dom_fee'], s['total_fee'], s['shipped'], s['created_at']))
            ship_ids[s['legacy_id']] = cur.fetchone()[0]
        for it in ds['shipping_items']:
            cur.execute("""insert into shipping_request_items (request_id, go_id, description, qty)
                values (%s,%s,%s,%s)""",
                (ship_ids[it['request']], go_ids.get(it['go']), it['description'], it['qty']))

        for l in ds['listings']:
            cur.execute("""insert into listings (legacy_id, name, category, price,
                image_url, qty, note, status, created_at)
                values (%s,%s,%s,%s,%s,%s,%s,%s,coalesce(%s, now())) returning id""",
                (l['legacy_id'], l['name'], l['category'], l['price'], l['image_url'],
                 l['qty'], l['note'], l['status'], l['created_at']))
            listing_ids[l['legacy_id']] = cur.fetchone()[0]
        for v in ds['variants']:
            cur.execute("insert into listing_variants (listing_id, name, qty) values (%s,%s,%s) returning id",
                        (listing_ids[v['listing']], v['name'], v['qty']))
            variant_ids[(v['listing'], v['name'])] = cur.fetchone()[0]

        for o in ds['shop_orders']:
            cur.execute("""insert into shop_orders (legacy_id, listing_id, variant_id,
                username, email, qty, unit_price, payment_status, fulfillment,
                created_at, updated_at)
                values (%s,%s,%s,%s,%s,%s,%s,%s,%s,coalesce(%s, now()),coalesce(%s, now()))""",
                (o['legacy_id'], listing_ids[o['listing']],
                 variant_ids.get(o['variant']) if o['variant'] else None,
                 o['username'], o['email'], o['qty'], o['unit_price'],
                 o['payment_status'], o['fulfillment'], o['created_at'], o['updated_at']))

        for o in ds['store_orders']:
            cur.execute("""insert into store_orders (legacy_id, go_id, sub_item_id,
                store, album_version, qty, unit_cost, status, notes, created_at, updated_at)
                values (%s,%s,%s,%s,%s,%s,%s,%s,%s,coalesce(%s, now()),coalesce(%s, now()))""",
                (o['legacy_id'], go_ids.get(o['go']),
                 si_ids.get(o['si']) if o['si'] else None,
                 o['store'], o['album_version'], o['qty'], o['unit_cost'],
                 o['status'], o['notes'], o['created_at'], o['updated_at']))

        conn.commit()
        print('=== loaded counts (db vs intended) ===')
        for table, key in [('gos','gos'), ('sub_items','sub_items'), ('members','members'),
                           ('versions','versions'), ('sets','sets'), ('claims','claims'),
                           ('payments','payments'), ('gc_members','gc'),
                           ('shipping_requests','shipping'),
                           ('shipping_request_items','shipping_items'),
                           ('listings','listings'), ('listing_variants','variants'),
                           ('shop_orders','shop_orders'), ('store_orders','store_orders')]:
            cur.execute(f'select count(*) from {table}')
            n = cur.fetchone()[0]
            flag = '' if n == len(ds[key]) else '  <-- MISMATCH'
            print(f'  {table:24s} {n:6d} / {len(ds[key])}{flag}')
```

- [ ] **Step 2: Run against the sandbox** — Jinghan runs `SUPABASE_DB_URL='<session pooler URI>' python3 db/migrate_from_xlsx.py` (or exports the var once). Expected: zero MISMATCH lines, no unique-violation errors from `claims_slot_unique` (the replay guarantees no duplicate slots — a violation here means a replay bug, stop and fix).

- [ ] **Step 3: Spot-check via MCP `execute_sql`** — `select count(*) from claims where set_id is not null` vs the sheet's set-based claim count; `select g.name, count(c.id) from gos g join sub_items s on s.go_id=g.id join claims c on c.sub_item_id=s.id group by g.name` compared against a per-GO count from the xlsx (`python3 -c` one-liner over the joiners sheet).

- [ ] **Step 4: Commit** — `git add db/migrate_from_xlsx.py && git commit -m "db: migration loader + count validation"`

---

### Task 9: Frontend — supabase-js, config, and the `db` module (reads)

**Files:**
- Modify: `index.html` — add CDN script tag next to the existing `<script>` block; add the `db` module right above the current `apiGet` (line ~4890); modify `tryParse` (line 5171) and `parseMembers` (line 5175).

**Interfaces:**
- Produces (consumed by Tasks 10-14):
  - `sb` — the supabase client.
  - `db.getGOsList() → {gos:[legacy go rows with .subItems]}`
  - `db.getGOBoard(goId) → {claims, secured_sets, closed_subitems, subitem_deadlines, subitem_payment_due}` (exact legacy shapes)
  - `db.getMyOrders(username) → {claims, payments, shop_orders, shipping}`
  - `db.getPayments() / db.getListings() / db.getShopOrders() / db.getStoreOrders() / db.getGcAdded() / db.getShipping()` — legacy response shapes
  - `claimRowToLegacy(c)`, `payRowToLegacy(p)`, `shopOrderToLegacy(o)` mappers

- [ ] **Step 1: Add the CDN tag and config.** Immediately before the main `<script>`:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"></script>
```

At the top of the main script (replacing `DEFAULT_API_URL`/`API_URL` at `index.html:4890-4891` — but leave `API_URL` defined as a truthy constant for now so the ~40 `if (API_URL)` guards keep working until Task 14 removes them):

```js
const SUPABASE_URL = 'https://kkzmvuqfqbonsxebzaii.supabase.co';
const SUPABASE_ANON_KEY = '<anon key from MCP get_publishable_keys — the JWT one>';
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const API_URL = 'supabase';   // truthy: legacy guards stay live until Task 14
```

- [ ] **Step 2: Add the mappers + read functions** (above the legacy `apiGet`):

```js
// ── Supabase data layer ────────────────────────────────────────────────────
// Maps normalized rows into the EXACT legacy shapes the render code consumes.
const CLAIM_SELECT = 'id, sub_item_id, username, email, qty, is_ot, assigned_version,' +
  ' status, payment_status, fulfillment, created_at, updated_at,' +
  ' members(name), versions(name), sets(set_no), sub_items!inner(go_id)';

function claimRowToLegacy(c) {
  return {
    claim_id: c.id,
    go_id: c.sub_items.go_id,
    sub_item_id: c.sub_item_id,
    username: c.username,
    email: c.email || '',
    member_or_version: (c.members && c.members.name) || (c.versions && c.versions.name) || '',
    set_num: c.sets ? c.sets.set_no : '',
    qty: c.qty,
    assigned_vers: c.is_ot ? 'OT' : (c.assigned_version || ''),
    claim_status: c.status,
    payment_status: c.payment_status,
    fulfillment: c.fulfillment || '',
    created_at: c.created_at,
    updated_at: c.updated_at
  };
}
function payRowToLegacy(p) {
  return {
    payment_id: p.id, username: p.username,
    go_id: p.is_shop ? 'shop' : p.go_id,
    go_name: p.is_shop ? 'Shop' : ((p.gos && p.gos.name) || ''),
    amount: p.amount, method: p.method, transaction_id: p.transaction_id,
    proof_url: p.proof_url, email: p.email, status: p.status,
    created_at: p.created_at, note: p.note || ''
  };
}
function shopOrderToLegacy(o) {
  return {
    order_id: o.id, listing_id: o.listing_id,
    listing_name: (o.listings && o.listings.name) || '',
    variant: (o.listing_variants && o.listing_variants.name) || '',
    username: o.username, email: o.email || '', qty: o.qty,
    unit_price: o.unit_price, payment_status: o.payment_status,
    fulfillment: o.fulfillment || '', created_at: o.created_at, updated_at: o.updated_at
  };
}
function goRowToLegacy(g) {
  return {
    go_id: g.id, name: g.name, artist: g.artist || '', type: g.type, status: g.status,
    deadline: g.deadline, payment_deadline: g.payment_deadline, min_secure: g.min_secure,
    subItems: (g.sub_items || [])
      .slice().sort((a, b) => a.position - b.position)
      .map(si => ({
        sub_item_id: si.id, name: si.name, kind: si.kind,
        members: (si.members || []).slice().sort((a, b) => a.position - b.position).map(m => m.name),
        versions: (si.versions || []).slice().sort((a, b) => a.position - b.position).map(v => v.name),
        price: si.price, ot_price: si.ot_price,
        // Batch mode round-trips through the legacy negative-min_secure sentinel
        // so isBatch() and every render branch stay untouched.
        min_secure: si.order_mode === 'batch' ? -(si.batch_size || 0)
                    : (si.min_secure != null ? si.min_secure : g.min_secure),
        image_url: si.image_url || '',
        closed: si.closed, deadline: si.deadline, pay_due: si.pay_due
      }))
  };
}
function dbThrow(res) { if (res.error) throw res.error; return res.data; }

const db = {
  async getGOsList() {
    const data = dbThrow(await sb.from('gos')
      .select('id, name, artist, type, status, deadline, payment_deadline, min_secure, created_at,' +
        ' sub_items(id, name, kind, order_mode, batch_size, price, ot_price, min_secure,' +
        ' image_url, position, closed, deadline, pay_due, members(name, position), versions(name, position))')
      .order('created_at'));
    return { gos: data.map(goRowToLegacy) };
  },
  async getGOBoard(goId) {
    const [cl, st, si] = await Promise.all([
      sb.from('claims').select(CLAIM_SELECT).eq('sub_items.go_id', goId),
      sb.from('sets').select('set_no, status, sub_items!inner(id, go_id)')
        .eq('sub_items.go_id', goId).eq('status', 'secured'),
      sb.from('sub_items').select('id, closed, deadline, pay_due').eq('go_id', goId)
    ]);
    return {
      claims: dbThrow(cl).map(claimRowToLegacy),
      secured_sets: dbThrow(st).map(s => ({ go_id: goId, sub_item_id: s.sub_items.id, set_num: s.set_no })),
      closed_subitems: si.data.filter(x => x.closed).map(x => ({ go_id: goId, sub_item_id: x.id })),
      subitem_deadlines: si.data.filter(x => x.deadline).map(x => ({ go_id: goId, sub_item_id: x.id, deadline: x.deadline })),
      subitem_payment_due: si.data.filter(x => x.pay_due).map(x => ({ go_id: goId, sub_item_id: x.id, due_date: x.pay_due }))
    };
  },
  async getMyOrders(username) {
    const u = String(username || '').trim().replace(/^@/, '');
    const [cl, pay, so, sh] = await Promise.all([
      sb.from('claims').select(CLAIM_SELECT).eq('username', u),
      sb.from('payments').select('*, gos(name)').eq('username', u),
      sb.from('shop_orders').select('*, listings(name), listing_variants(name)').eq('username', u),
      sb.from('shipping_status').select('*').eq('username', u)
    ]);
    return {
      claims: dbThrow(cl).map(claimRowToLegacy),
      payments: dbThrow(pay).map(payRowToLegacy),
      shop_orders: dbThrow(so).map(shopOrderToLegacy),
      shipping: dbThrow(sh).map(r => ({ request_id: r.id, username: r.username,
        ems_fee: r.ems_fee, dom_fee: r.dom_fee, total_fee: r.total_fee,
        shipped: r.shipped, created_at: r.created_at }))
    };
  },
  async getPayments() {
    const data = dbThrow(await sb.from('payments').select('*, gos(name)').order('created_at'));
    return { payments: data.map(payRowToLegacy) };
  },
  async getListings() {
    const data = dbThrow(await sb.from('listings').select('*, listing_variants(id, name, qty)').order('created_at'));
    return { listings: data.map(l => ({
      listing_id: l.id, name: l.name, category: l.category, price: l.price,
      image_url: l.image_url || '', qty: l.qty, note: l.note || '', status: l.status,
      created_at: l.created_at,
      variants: (l.listing_variants || []).length
        ? JSON.stringify(l.listing_variants.map(v => ({ name: v.name, qty: v.qty }))) : ''
    })) };
  },
  async getShopOrders() {
    const data = dbThrow(await sb.from('shop_orders')
      .select('*, listings(name), listing_variants(name)').order('created_at'));
    return { shop_orders: data.map(shopOrderToLegacy) };
  },
  async getStoreOrders() {
    const data = dbThrow(await sb.from('store_orders')
      .select('*, gos(name), sub_items(name)').order('created_at'));
    return { store_orders: data.map(o => ({
      order_id: o.id, go_id: o.go_id, go_name: (o.gos && o.gos.name) || '',
      sub_item_id: o.sub_item_id, sub_item_name: (o.sub_items && o.sub_items.name) || '',
      store: o.store, album_version: o.album_version || '', qty: o.qty,
      unit_cost: o.unit_cost, status: o.status, notes: o.notes || '',
      created_at: o.created_at, updated_at: o.updated_at
    })) };
  },
  async getGcAdded() {   // admin-only table; anon gets an empty list, which is fine pre-login
    const data = dbThrow(await sb.from('gc_members').select('go_id, username'));
    return { gc_added: data };
  },
  async getShipping() {  // admin: full requests incl. addresses + items
    const data = dbThrow(await sb.from('shipping_requests')
      .select('*, shipping_request_items(id, go_id, description, qty)').order('created_at'));
    return { requests: data.map(r => ({
      request_id: r.id, username: r.username, full_name: r.full_name,
      address1: r.address1, address2: r.address2 || '', city: r.city, state: r.state,
      postal: r.postal, country: r.country, notes: r.notes || '', email: r.email || '',
      card_count: (r.shipping_request_items || []).reduce((a, i) => a + (i.qty || 0), 0),
      ems_fee: r.ems_fee, dom_fee: r.dom_fee, total_fee: r.total_fee,
      shipped: r.shipped, created_at: r.created_at,
      items: JSON.stringify((r.shipping_request_items || [])
        .map(i => ({ type: 'item', id: i.id, label: i.description })))
    })) };
  }
};
```

- [ ] **Step 3: Make the two parsers array-tolerant** (goRowToLegacy returns real arrays, legacy sheets returned JSON strings). In `tryParse` (`index.html:5171`) and `parseMembers` (`:5175`), add as the first line of each:

```js
  if (Array.isArray(val)) return val;
```

(For `parseMembers` place it after the `if (!val) return [];` guard.)

- [ ] **Step 4: Verify in a browser** — `python3 -m http.server 8080` in the repo root, open `http://localhost:8080/index.html`, and in DevTools console run `await db.getGOsList()` and `await db.getGOBoard((await db.getGOsList()).gos[0].go_id)`; both return populated legacy-shaped objects with no console errors.

- [ ] **Step 5: Commit** — `git add index.html && git commit -m "frontend: supabase client + db read layer with legacy-shape mappers"`

---

### Task 10: Frontend — swap all read paths onto `db.*`

**Files:**
- Modify: `index.html` at each call site below.

**Interfaces:**
- Consumes: `db.*` from Task 9.

- [ ] **Step 1: Apply the read swaps.** Every `apiGet(action, …)` becomes the matching `db.*` call — same response shapes, so surrounding code is untouched:

| Line (pre-edit) | Legacy call | Replacement |
|---|---|---|
| 835 | `apiGet('getListings')` | `db.getListings()` |
| 1034 | `apiGet('getGOBoard', { go_id: goId })` | `db.getGOBoard(goId)` |
| 1042-1046 | 5-call fallback (`getGOClaims` + 4 flag calls) | delete the whole `else` branch — `db.getGOBoard` cannot "pre-redeploy 404"; keep only the board path |
| 1812 | `apiGet('getMyOrders', { username: raw.trim() })` | `db.getMyOrders(raw.trim())` |
| 1817-1820 | 4-call fallback | delete the fallback branch |
| 3198 | `apiGet('getListings')`, `apiGet('getShopOrders')` | `db.getListings()`, `db.getShopOrders()` |
| 3218 | `apiGet('getPayments')` | `db.getPayments()` |
| 3238 | `apiGet('getStoreOrders')` | `db.getStoreOrders()` |
| 3251 | `apiGet('getShipping')` | `db.getShipping()` |
| 4974 | `apiGet('getGOsList')` | `db.getGOsList()` |
| 4977 | `apiGet('getAllGOs')` fallback | delete the fallback (`getGOsList` is now authoritative; `gosData = result` stands) |
| 5108 | `apiGet('getGcAdded')` | `db.getGcAdded()` |
| 5360 | `apiGet('ping')` (settings test button) | `sb.from('gos').select('id', { head: true, count: 'exact' })` |

Also line 5348 `apiPost('bootstrap', {})` — delete (schema bootstrap is a migration concern now).

- [ ] **Step 2: Verify in the browser** — reload `http://localhost:8080/index.html`: landing renders all 18 GOs grouped by artist; opening the biggest GO (This&That POB) renders its full board; My Orders lookup for a known username (pick one from the data, e.g. `rislin`) lists their claims. Console shows zero failed requests.

- [ ] **Step 3: Commit** — `git add index.html && git commit -m "frontend: read paths on Supabase"`

---

### Task 11: Frontend — joiner writes through RPCs

**Files:**
- Modify: `index.html` at the call sites below.

**Interfaces:**
- Consumes: anon RPCs (Task 3). `db` gains:

```js
// Add to the db object:
async submitClaim(payload) {
  // payload.claims come in legacy shape from claimsToWrite (go_id, sub_item_id,
  // member_or_version, qty, assigned_vers, username, email).
  const meta = {};   // sub_item_id -> kind, to route member vs version
  Object.values(allGOs).forEach(go => (go.subItems || []).forEach(si => { meta[si.id] = si.kind; }));
  const p_claims = payload.claims.map(c => ({
    sub_item_id: c.sub_item_id,
    username: c.username, email: c.email || null,
    member: (meta[c.sub_item_id] === 'versioned') ? null : (c.member_or_version || null),
    version: (meta[c.sub_item_id] === 'versioned') ? (c.member_or_version || null) : null,
    qty: c.qty || 1,
    is_ot: c.assigned_vers === 'OT',
    assigned_version: (c.assigned_vers && c.assigned_vers !== 'OT') ? c.assigned_vers : null
  }));
  const { data, error } = await sb.rpc('submit_claim', { p_claims });
  if (error) throw error;
  return data;    // {ok, claim_ids, set_nums} — same keys the legacy backend returned
},
async submitPayment(proof) {
  const { data, error } = await sb.rpc('submit_payment', { p: proof });
  if (error) throw error;
  return data;
},
async submitShipping(req) {
  const items = (req.items || []).map(it => ({ go_id: null, description: it.label || '', qty: 1 }));
  const { data, error } = await sb.rpc('submit_shipping', { p: { ...req, items } });
  if (error) throw error;
  return data;
},
async placeShopOrder(payload) {
  const { data, error } = await sb.rpc('place_shop_order', { p: payload });
  if (error) throw error;
  return data;
}
```

- [ ] **Step 1: Add the four methods above to `db`,** then swap the call sites:
  - `index.html:1786` `apiPost('submitClaim', { claims })` → `db.submitClaim({ claims })` (response handling unchanged — same `ok`/`error`/`set_nums` keys).
  - `index.html:2183` `apiPost('submitShipping', req)` → `db.submitShipping(req)`.
  - `index.html:2215` and `:4797` `apiPost('submitPayment', proof)` → `db.submitPayment(proof)`.
  - `index.html:964` `apiPost('placeShopOrder', payload)` → `db.placeShopOrder(payload)`.
  Check each payload at its build site: `submitPayment`'s `proof` must carry `go_id` as the uuid (or `'shop'`), and `placeShopOrder`'s payload must carry `listing_id`/`variant_id` as uuids — they do once Task 10's reads populate ids from the DB, but verify the variant path passes the variant **id** (from `db.getListings`' parsed variants) rather than the name; adjust the payload builder at `:964`'s enclosing function if it currently sends the name.

- [ ] **Step 2: Verify in the browser** — place a set claim, a batch claim, a versioned claim, an OT claim, and a shop order against the sandbox; each appears on the board/My Orders after reload; two claims on the same member land in different sets.

- [ ] **Step 3: Clean up test writes** — via `execute_sql`, delete the claims/orders created while testing (match on the test username used, e.g. `delete from claims where username = 'claudetest'`).

- [ ] **Step 4: Commit** — `git add index.html && git commit -m "frontend: joiner writes via anon RPCs"`

---

### Task 12: Frontend — real admin auth

**Files:**
- Modify: `index.html:3275-3322` (admin gate) and the login overlay markup (search for `admin-login-overlay`).

**Interfaces:**
- Consumes: a Supabase auth user **Jinghan creates herself** in the dashboard (Authentication → Users → Add user, with a real password — not `kpop2026`). This is the one manual step in this task.
- Produces: `isAdmin` now derives from the Supabase session; all direct table writes and admin RPCs carry the JWT automatically via `sb`.

- [ ] **Step 1: Replace the gate.** Delete `const ADMIN_PASS = 'kpop2026';` and rewrite:

```js
let isAdmin = false;   // set by the auth listener below

sb.auth.onAuthStateChange((_event, session) => {
  const was = isAdmin;
  isAdmin = !!session;
  if (was !== isAdmin) applyAdminState();
});
// On boot (place near the existing init/sync bootstrap):
sb.auth.getSession().then(({ data: { session } }) => {
  isAdmin = !!session;
  applyAdminState();
});

function logoutAdmin() {
  sb.auth.signOut();
  isAdmin = false;
  applyAdminState();
  showPage('orders');
}

async function submitAdminPass() {
  const email = document.getElementById('admin-email-input').value.trim();
  const password = document.getElementById('admin-pass-input').value;
  const err = document.getElementById('admin-pass-err');
  err.textContent = '';
  const { error } = await sb.auth.signInWithPassword({ email, password });
  if (error) { err.textContent = 'Login failed — check email and password.'; return; }
  isAdmin = true;
  closeAdminLogin();
  applyAdminState();
  syncFromBackend();   // pull full data now that we're admin
  showPage('admin');
}
```

- [ ] **Step 2: Add the email field** to the login overlay markup, above the password input, matching its styling:

```html
<input id="admin-email-input" type="email" autocomplete="username" placeholder="Email">
```

- [ ] **Step 3: Verify** — Jinghan creates the auth user; log in through the UI, confirm the admin tab appears, session survives a reload (supabase-js persists to localStorage), an admin-only read (`db.getGcAdded()` returning rows, `db.getShipping()` returning the test request) works after login and returns nothing before login, and Log out drops back to joiner view.

- [ ] **Step 4: Commit** — `git add index.html && git commit -m "frontend: Supabase email+password admin auth"`

---

### Task 13: Frontend — admin writes

**Files:**
- Modify: `index.html` at each call site below.

**Interfaces:**
- Consumes: admin RPCs (Task 4); authenticated direct table access under `admin_all` policies. `db` gains the methods below. All single-row updates are direct table writes; multi-row/transactional ones are RPCs.

- [ ] **Step 1: Add admin methods to `db`:**

```js
// Add to the db object:
async updateClaim(d) {
  if (d.set_num !== undefined && d.set_num !== null && d.set_num !== '') {
    const r = await sb.rpc('move_claim', { p_claim_id: d.claim_id, p_set_no: parseInt(d.set_num) });
    if (r.error) throw r.error;
  }
  const patch = {};
  if (d.claim_status)   patch.status = d.claim_status;
  if (d.payment_status) patch.payment_status = d.payment_status;
  if (d.fulfillment)    patch.fulfillment = d.fulfillment;
  if (Object.keys(patch).length) {
    const r = await sb.from('claims').update(patch).eq('id', d.claim_id);
    if (r.error) throw r.error;
  }
  return { ok: true };
},
async deleteClaim(claimId) {
  const r = await sb.from('claims').delete().eq('id', claimId);
  if (r.error) throw r.error;
  return { ok: true };
},
async secureSet(subItemId, setNum, secured) {
  const { data, error } = await sb.rpc('secure_set',
    { p_sub_item_id: subItemId, p_set_no: parseInt(setNum), p_secured: !!secured });
  if (error) throw error;
  return data;
},
async saveGO(go) {
  // go: in-memory GO object (allGOs[id] shape) + optional go_id for updates.
  const p = {
    go_id: go.go_id || null, name: go.name, artist: go.artist || null,
    type: go.type, status: go.status || 'open',
    deadline: go.deadline || null, payment_deadline: go.paymentDeadline || null,
    min_secure: parseInt(go.minSecure) || 7,
    sub_items: (go.subItems || []).map(si => {
      const ms = parseInt(si.minSecure);
      return {
        id: /^[0-9a-f-]{36}$/.test(si.id || '') ? si.id : null,   // temp client ids -> insert
        name: si.name, kind: si.kind || 'random',
        order_mode: ms < 0 ? 'batch' : 'set',
        batch_size: ms < 0 ? Math.abs(ms) : null,
        price: parseFloat(si.price) || 0, ot_price: parseFloat(si.otPrice) || 0,
        min_secure: ms >= 0 ? ms : null,
        image_url: si.imageUrl || null,
        members: si.members || [], versions: si.versions || []
      };
    })
  };
  const { data, error } = await sb.rpc('save_go', { p });
  if (error) throw error;
  return data;   // {ok, go_id, sub_item_ids}
},
async deleteGO(goId) {
  const r = await sb.from('gos').delete().eq('id', goId);   // cascades; claims FK restrict
  if (r.error) throw r.error;                               // blocks if claims exist? No:
  return { ok: true };                                      // claims cascade via sub_items?
},
// NOTE: sub_items -> gos is ON DELETE CASCADE but claims -> sub_items is RESTRICT,
// so deleting a GO with claims errors. Legacy deleteGO removed claims first; mirror that:
async deleteGOWithClaims(goId) {
  const ids = dbThrow(await sb.from('sub_items').select('id').eq('go_id', goId)).map(x => x.id);
  if (ids.length) {
    const r1 = await sb.from('claims').delete().in('sub_item_id', ids);
    if (r1.error) throw r1.error;
  }
  const r = await sb.from('gos').delete().eq('id', goId);
  if (r.error) throw r.error;
  return { ok: true };
},
async setGcAdded(goId, username, added) {
  const u = String(username || '').trim().replace(/^@/, '');
  const r = added
    ? await sb.from('gc_members').upsert({ go_id: goId, username: u })
    : await sb.from('gc_members').delete().match({ go_id: goId, username: u });
  if (r.error) throw r.error;
  return { ok: true };
},
async setSubItemFlag(siId, patch) {    // {closed} | {deadline} | {pay_due}
  const r = await sb.from('sub_items').update(patch).eq('id', siId);
  if (r.error) throw r.error;
  return { ok: true };
},
async updatePayment(d) {
  const { data, error } = await sb.rpc('confirm_payment', { p: {
    payment_id: d.payment_id, status: d.status, note: d.note,
    amount: d.amount, username: d.username, method: d.method,
    transaction_id: d.transaction_id,
    is_shop: d.go_id === 'shop',
    paid_ids: d.paid_claim_ids || d.paid_order_ids || [],
    unpaid_ids: d.unpaid_claim_ids || d.unpaid_order_ids || []
  } });
  if (error) throw error;
  return data;
},
async deletePayment(id) {
  const r = await sb.from('payments').delete().eq('id', id);
  if (r.error) throw r.error;
  return { ok: true };
},
async applyCredit(d) {
  const { data, error } = await sb.rpc('apply_credit', { p: d });
  if (error) throw error;
  return data;
},
async reverseCredit(d) {
  const { data, error } = await sb.rpc('reverse_credit', { p: d });
  if (error) throw error;
  return data;
},
async saveListing(d) {           // create or update; d in legacy listing shape
  const row = { name: d.name, category: d.category, price: d.price,
    image_url: d.image_url || null, note: d.note || null, status: d.status || 'active',
    qty: d.variants ? null : (parseInt(d.qty) || 0) };
  let listingId = d.listing_id;
  if (listingId) {
    const r = await sb.from('listings').update(row).eq('id', listingId);
    if (r.error) throw r.error;
  } else {
    const r = await sb.from('listings').insert(row).select('id').single();
    if (r.error) throw r.error;
    listingId = r.data.id;
  }
  const variants = typeof d.variants === 'string' ? tryParse(d.variants, []) : (d.variants || []);
  const del = await sb.from('listing_variants').delete().eq('listing_id', listingId);
  if (del.error) throw del.error;
  if (variants.length) {
    const ins = await sb.from('listing_variants')
      .insert(variants.map(v => ({ listing_id: listingId, name: v.name, qty: parseInt(v.qty) || 0 })));
    if (ins.error) throw ins.error;
  }
  return { ok: true, listing_id: listingId };
},
async deleteListing(listingId) {
  const r = await sb.from('listings').delete().eq('id', listingId);
  if (r.error) throw r.error;
  return { ok: true };
},
async saveStoreOrder(d) {
  const row = { go_id: d.go_id || null, sub_item_id: d.sub_item_id || null,
    store: d.store, album_version: d.album_version || null,
    qty: parseInt(d.qty) || 1, unit_cost: d.unit_cost, status: d.status, notes: d.notes || null };
  if (d.order_id) {
    const r = await sb.from('store_orders').update(row).eq('id', d.order_id);
    if (r.error) throw r.error;
    return { ok: true, order_id: d.order_id };
  }
  const r = await sb.from('store_orders').insert(row).select('id').single();
  if (r.error) throw r.error;
  return { ok: true, order_id: r.data.id };
},
async deleteStoreOrder(orderId) {
  const r = await sb.from('store_orders').delete().eq('id', orderId);
  if (r.error) throw r.error;
  return { ok: true };
},
async updateShopOrder(d) {
  const patch = {};
  if (d.payment_status) patch.payment_status = d.payment_status;
  if (d.fulfillment)    patch.fulfillment = d.fulfillment;
  const r = await sb.from('shop_orders').update(patch).eq('id', d.order_id);
  if (r.error) throw r.error;
  return { ok: true };
},
async deleteShopOrder(orderId) {
  const r = await sb.from('shop_orders').delete().eq('id', orderId);
  if (r.error) throw r.error;
  return { ok: true };
},
async updateShipping(d) {
  const r = await sb.from('shipping_requests').update({
    ems_fee: d.ems_fee === '' ? null : d.ems_fee,
    dom_fee: d.dom_fee === '' ? null : d.dom_fee,
    total_fee: d.total_fee === '' ? null : d.total_fee,
    shipped: !!d.shipped
  }).eq('id', d.request_id);
  if (r.error) throw r.error;
  return { ok: true };
}
```

- [ ] **Step 2: Swap the admin call sites** (payload keys are already what the `db` methods take — each row lists old → new):

| Lines | Legacy | Replacement |
|---|---|---|
| 2662, 2676, 2691, 2700, 2711, 2834, 2889, 2901, 2916, 2928, 2941, 3861, 3904, 3999 | `apiPost('updateClaim', {…})` | `db.updateClaim({…})` (same object) |
| 2951, 3874, 3927, 3933, 3951 | `apiPost('deleteClaim', { claim_id })` | `db.deleteClaim(claimId)` |
| 2753/2755 | `secureSet` + `setSecuredSet` double-write | single `db.secureSet(siId, setNum, true)` |
| 2769/2770 | `unsecureSet` + `setSecuredSet` | single `db.secureSet(siId, setNum, false)` |
| 2723 | `setSubItemDeadline` | `db.setSubItemFlag(siId, { deadline: si.deadline \|\| null })` |
| 2733 | `setSubItemPayDue` | `db.setSubItemFlag(siId, { pay_due: si.payDue \|\| null })` |
| 2743 | `setClosedSubItem` | `db.setSubItemFlag(siId, { closed: !!si.closed })` |
| 2354 | `setGcAdded` | `db.setGcAdded(goId, username, added)` |
| 3153 | `createGO` | `db.saveGO(allGOs[id])` then `await syncFromBackend(true)` to re-key onto real uuids (drop the client-generated id entry from `allGOs` first) |
| 3768 | `updateGO` | `db.saveGO({ go_id: go.id, …same fields })` then `await syncFromBackend(true)` |
| 3800 | `deleteGO` | `db.deleteGOWithClaims(goId)` |
| 4161/4165 | `updateListing`/`createListing` | `db.saveListing(data)` |
| 4177 | `deleteListing` | `db.deleteListing(listingId)` |
| 4341/4345, 4357 | store order save/status | `db.saveStoreOrder(data)` |
| 4365 | `deleteStoreOrder` | `db.deleteStoreOrder(orderId)` |
| 4413 | `deleteShopOrder` | `db.deleteShopOrder(orderId)` |
| 4424, 4435 | `updateShopOrder` | `db.updateShopOrder({…})` |
| 4696, 4721, 4766 | `updatePayment` | `db.updatePayment(payload)` |
| 4709 | `deletePayment` | `db.deletePayment(id)` |
| 2239 | `applyCredit` | `db.applyCredit({ username: u, transaction_id: link, rows, paid_claim_ids: ba.paidIds, unpaid_claim_ids: ba.unpaidIds })` |
| (search `reverseCredit`) | `apiPost('reverseCredit', …)` | `db.reverseCredit({…})` |

`persistWrite(promise, label)` keeps working unchanged — `db.*` methods resolve to `{ok:true}` or reject, which its `res.ok === false` / catch path already handles.

- [ ] **Step 3: Verify in the browser (logged in as admin)** — edit a GO (rename a sub-item, add a member), secure and unsecure a set, toggle paid on a claim, confirm a payment with claim ids, apply + reverse a credit, create/edit/delete a listing, mark a store order, set shipping fees. Each survives a hard reload (i.e. actually persisted).

- [ ] **Step 4: Commit** — `git add index.html && git commit -m "frontend: admin writes via Supabase (direct + RPCs)"`

---

### Task 14: Frontend — image upload + legacy machinery removal

**Files:**
- Modify: `index.html` — New/Edit GO image field area (search `imageUrl` input in the admin GO form, near `si-kind-` handling at `:3100-3150`); delete legacy plumbing.

- [ ] **Step 1: Add the upload helper to `db`:**

```js
async uploadItemImage(file) {
  // Downscale client-side to keep uploads ~150KB.
  const img = await createImageBitmap(file);
  const scale = Math.min(1, 1000 / Math.max(img.width, img.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(img.width * scale);
  canvas.height = Math.round(img.height * scale);
  canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
  const blob = await new Promise(res => canvas.toBlob(res, 'image/jpeg', 0.8));
  const path = Date.now() + '-' + Math.random().toString(36).slice(2, 8) + '.jpg';
  const { error } = await sb.storage.from('item-images').upload(path, blob,
    { contentType: 'image/jpeg' });
  if (error) throw error;
  return sb.storage.from('item-images').getPublicUrl(path).data.publicUrl;
}
```

- [ ] **Step 2: Wire a file input** next to each image-URL field in the admin GO form (and the listing form), matching existing styling:

```html
<input type="file" accept="image/*" style="display:none" id="img-file-SIID"
       onchange="uploadSubItemImage(this, 'SIID')">
<button class="btn btn-ghost btn-sm" onclick="document.getElementById('img-file-SIID').click()">Upload</button>
```

```js
async function uploadSubItemImage(input, siId) {
  if (!input.files || !input.files[0]) return;
  try {
    const url = await db.uploadItemImage(input.files[0]);
    document.getElementById('si-img-' + siId).value = url;   // the existing URL field
    toast('Image uploaded.');
  } catch (e) { toast('Upload failed — try a smaller image.'); }
}
```

(Adapt the `si-img-` id to whatever the existing URL input's id pattern is at the form-building site; the URL-paste field stays.)

- [ ] **Step 3: Delete legacy machinery:**
  - `fetchWithTimeout`, `API_TIMEOUT_MS`, `retryDelay`, `apiGet`, `apiPost` (`index.html:4896-4941`).
  - The `const API_URL = 'supabase'` shim: remove it and every `if (API_URL)`/`API_URL &&` guard (the writes are unconditional now), plus the API-URL settings field UI and its `localStorage.getItem('go_api_url')` handling (search `go_api_url`, `sheets-btn`).
  - The `getAllGOs` fallback comment block and any `bd.claims !== undefined` cache-workaround remnants in `loadGOClaims`.
  - `grep -n "apiGet\|apiPost\|API_URL\|go_api_url" index.html` must return zero hits when done.

- [ ] **Step 4: Verify in the browser** — full click-through of joiner landing + one claim + admin GO edit with an image upload; the uploaded image renders from `…/storage/v1/object/public/item-images/…`.

- [ ] **Step 5: Commit** — `git add index.html && git commit -m "frontend: Storage image upload; remove Apps Script plumbing"`

---

### Task 15: Parity harness

Spec success criterion 1: same boards from the old shape-builders (xlsx snapshot) and the new DB layer, for every GO in history.

**Files:**
- Create: `db/export_snapshot.py` — dumps legacy-shaped data from the xlsx to `tests/fixtures/snapshot.json`
- Create: `tests/parity.mjs`

**Interfaces:**
- Consumes: `build_dataset` from `migrate_from_xlsx.py`; the live sandbox DB (anon REST); `buildSetsFromClaims`/`buildVersionedClaims`/`buildBatchClaims`/`deriveSetStatus`/`nextSetNum` extracted verbatim from `index.html`.

- [ ] **Step 1: Write `db/export_snapshot.py`**

```python
#!/usr/bin/env python3
"""Dump the xlsx in legacy API shapes for the parity harness."""
import json, os
from openpyxl import load_workbook
from migrate_from_xlsx import XLSX, rows_as_dicts, parse_members, resolve_go_sheets, parse_int

def main():
    wb = load_workbook(XLSX)
    gos = rows_as_dicts(wb['_gos'])
    joiners = [c for c in rows_as_dicts(wb['joiners']) if c.get('claim_id')]
    sheets = resolve_go_sheets(wb, gos, joiners)
    out = {
        'gos': [], 
        'claims': [{k: (str(v) if v is not None else '') for k, v in c.items()} for c in joiners],
        'secured_sets': rows_as_dicts(wb['secured_sets']),
        'closed_subitems': rows_as_dicts(wb['closed_subitems']),
    }
    for g in gos:
        ws = sheets.get(g['go_id'])
        out['gos'].append({
            'go_id': g['go_id'], 'name': g['name'], 'type': g.get('type') or 'photocard',
            'status': g.get('status') or 'open',
            'min_secure': parse_int(g.get('min_secure')) or 7,
            'subItems': [
                {k: (str(v) if v is not None else '') for k, v in r.items()}
                for r in (rows_as_dicts(ws) if ws is not None else [])
            ]
        })
    dst = os.path.join(os.path.dirname(__file__), '..', 'tests', 'fixtures', 'snapshot.json')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'w') as f:
        json.dump(out, f, default=str)
    print('wrote', dst)

if __name__ == '__main__':
    main()
```

- [ ] **Step 2: Write `tests/parity.mjs`**

```js
#!/usr/bin/env node
// Parity: legacy pipeline (snapshot.json -> extracted builders) vs new pipeline
// (Supabase REST -> claimRowToLegacy -> same builders). Boards must match.
// Usage: SUPABASE_URL=... SUPABASE_ANON_KEY=... node tests/parity.mjs
import fs from 'node:fs';
import vm from 'node:vm';

const src = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');

// Extract a top-level `function name(...) {...}` by balanced-brace scan.
function extractFunction(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`function ${name} not found`);
  let i = src.indexOf('{', start), depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  throw new Error(`unbalanced braces in ${name}`);
}

const sandbox = { securedSets: {}, console };
vm.createContext(sandbox);
for (const fn of ['buildSetsFromClaims', 'buildVersionedClaims', 'buildBatchClaims',
                  'deriveSetStatus', 'nextSetNum', 'parseMembers', 'tryParse',
                  'claimRowToLegacy', 'isBatch'])
  vm.runInContext(extractFunction(fn), sandbox);

const BASE = process.env.SUPABASE_URL + '/rest/v1';
const HDRS = { apikey: process.env.SUPABASE_ANON_KEY,
               Authorization: 'Bearer ' + process.env.SUPABASE_ANON_KEY };
async function rest(path) {
  const r = await fetch(BASE + path, { headers: HDRS });
  if (!r.ok) throw new Error(path + ' -> ' + r.status);
  return r.json();
}

// Canonical board form: slots keyed by member with only cross-system-stable fields.
function canonSets(sets) {
  return sets.map(s => ({
    num: s.num, status: s.status,
    slots: Object.fromEntries(Object.entries(s.slots).map(([m, v]) =>
      [m, v && { user: String(v.user).replace(/^@/, '').toLowerCase(),
                 ot: !!v.ot, claim_status: v.claim_status || 'pending',
                 payment: v.payment || 'unpaid' }]))
  }));
}
function canonClaims(claims) {
  return claims
    .map(c => ({ user: String(c.user).replace(/^@/, '').toLowerCase(),
                 member: c.member || '', qty: c.qty || 1,
                 claim_status: c.claim_status || 'pending', payment: c.payment || 'unpaid' }))
    .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
}

const snap = JSON.parse(fs.readFileSync(new URL('./fixtures/snapshot.json', import.meta.url)));
const SET_KINDS = new Set(['photocard', 'member', 'member-set']);

// New-side data, fetched once.
const dbGos = await rest('/gos?select=id,legacy_id,min_secure,sub_items(id,legacy_id,kind,order_mode,batch_size,min_secure,members(name,position))');
const dbSecured = await rest('/sets?select=set_no,sub_items!inner(legacy_id,go_id)&status=eq.secured');
const dbClaims = await rest('/claims?select=id,legacy_id,sub_item_id,username,email,qty,is_ot,assigned_version,status,payment_status,fulfillment,created_at,updated_at,members(name),versions(name),sets(set_no),sub_items!inner(go_id,legacy_id)');

let failures = 0;
for (const g of snap.gos) {
  const dbGo = dbGos.find(x => x.legacy_id === g.go_id);
  if (!dbGo) { console.error(`MISSING GO in db: ${g.go_id}`); failures++; continue; }
  const legacyClaims = snap.claims.filter(c => c.go_id === g.go_id);
  const newClaimsRaw = dbClaims.filter(c => c.sub_items.go_id === dbGo.id);
  const newClaims = newClaimsRaw.map(c => sandbox.claimRowToLegacy({
    ...c, sub_items: { go_id: c.sub_items.go_id } }));

  for (const si of g.subItems) {
    if (!si.sub_item_id) continue;
    const dbSi = dbGo.sub_items.find(x => x.legacy_id === si.sub_item_id);
    if (!dbSi) { console.error(`MISSING sub_item ${g.go_id}/${si.sub_item_id}`); failures++; continue; }
    const kind = si.kind || g.type || 'photocard';
    const ms = parseInt(si.min_secure) || 7;
    const members = sandbox.parseMembers(si.members);
    const oldOfSi = legacyClaims.filter(c => c.sub_item_id === si.sub_item_id);
    const newOfSi = newClaims.filter(c => c.sub_item_id === dbSi.id);

    // securedSets keyed per pipeline's own sub_item ids.
    sandbox.securedSets = {};
    for (const r of snap.secured_sets)
      if (r.sub_item_id === si.sub_item_id) sandbox.securedSets[si.sub_item_id + '|' + parseInt(r.set_num)] = true;
    const oldBoard = SET_KINDS.has(kind) && ms >= 0
      ? canonSets(sandbox.buildSetsFromClaims(oldOfSi, si.sub_item_id, members))
      : canonClaims(ms < 0 ? sandbox.buildBatchClaims(oldOfSi, si.sub_item_id)
                           : sandbox.buildVersionedClaims(oldOfSi, si.sub_item_id));
    sandbox.securedSets = {};
    for (const r of dbSecured)
      if (r.sub_items.legacy_id === si.sub_item_id) sandbox.securedSets[dbSi.id + '|' + r.set_no] = true;
    const dbMembers = (dbSi.members || []).sort((a, b) => a.position - b.position).map(m => m.name);
    const newBoard = SET_KINDS.has(kind) && ms >= 0
      ? canonSets(sandbox.buildSetsFromClaims(newOfSi, dbSi.id, dbMembers))
      : canonClaims(ms < 0 ? sandbox.buildBatchClaims(newOfSi, dbSi.id)
                           : sandbox.buildVersionedClaims(newOfSi, dbSi.id));

    const a = JSON.stringify(oldBoard), b = JSON.stringify(newBoard);
    if (a !== b) {
      failures++;
      console.error(`MISMATCH ${g.name} / ${si.name} (${si.sub_item_id})`);
      console.error('  old:', a.slice(0, 400));
      console.error('  new:', b.slice(0, 400));
    }
  }
}
console.log(failures === 0 ? `PARITY OK — all ${snap.gos.length} GOs match`
                           : `${failures} mismatches`);
process.exit(failures === 0 ? 0 : 1);
```

- [ ] **Step 3: Run it** — `python3 db/export_snapshot.py && SUPABASE_URL=… SUPABASE_ANON_KEY=… node tests/parity.mjs`. Expected: `PARITY OK`. Debug loop: any mismatch is either a replay bug (fix `build_sets_from_claims`, re-run Task 8's load, re-run harness) or a mapper bug (fix `claimRowToLegacy`). Canonicalization may need small adjustments (e.g. fulfillment defaults) — adjust only fields that are genuinely cosmetic, never `user`/`member`/`num`/`status`.

- [ ] **Step 4: Commit** — `git add db/export_snapshot.py tests/parity.mjs tests/fixtures/snapshot.json && git commit -m "test: parity harness — legacy builders vs Supabase pipeline"`

---

### Task 16: Manual walkthrough + performance check

**Files:** none (verification only; fix bugs found as they surface, committing per fix).

- [ ] **Step 1: Joiner flows** (fresh incognito window, phone width ~390px, `http://localhost:8080/index.html`):
  set-slot claim · OT full-set claim · batch claim · versioned claim · merch claim · shop order (with + without variant) · payment proof submission · shipping request · My Orders lookup shows all of the above with correct prices/statuses.
- [ ] **Step 2: Admin flows** (log in): create GO (all four kinds of sub-item, with image upload) · edit GO (add/remove member, change price) · close/reopen a POB · secure + unsecure a set · drag a claim to another set · mark claim paid/unpaid · delete a claim · confirm + reject a payment · apply + reverse a credit · GC-added toggle · store order create/status/delete · listing create/edit/delete · shop-order status + delete · shipping fees + mark shipped · delete a test GO.
- [ ] **Step 3: Performance (success criterion 3)** — DevTools Network: landing load, biggest-GO open (This&That POB), and admin login→full render each complete under 1s of network time. Record numbers in the task notes.
- [ ] **Step 4: Screenshots** — phone-width screenshots of landing, an open GO board, My Orders, admin GO detail (browser tooling or manual). Save to `scratchpad/` for review, don't commit.
- [ ] **Step 5: Re-run Task 6's RLS script and Task 15's parity harness** once more after all fixes. Both green.
- [ ] **Step 6: Commit any fixes** — `git commit -m "frontend: walkthrough fixes"` (as needed).

---

### Task 17: Keep-alive GitHub Action

**Files:**
- Create: `.github/workflows/keepalive.yml`

- [ ] **Step 1: Write the workflow** (anon key is already public in `index.html`, so no secrets needed):

```yaml
name: supabase-keepalive
on:
  schedule:
    - cron: '17 9 * * *'   # daily 09:17 UTC
  workflow_dispatch: {}
jobs:
  ping:
    runs-on: ubuntu-latest
    steps:
      - name: One trivial query so the free-tier project never pauses
        run: |
          curl -sf "https://kkzmvuqfqbonsxebzaii.supabase.co/rest/v1/gos?select=id&limit=1" \
            -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${ANON_KEY}" > /dev/null
        env:
          ANON_KEY: <anon key — same value as in index.html>
```

- [ ] **Step 2: Verify** — after the branch is pushed, trigger `workflow_dispatch` once from the Actions tab (note: scheduled workflows only run from the default branch, so the cron becomes active at cutover when the branch merges — that is fine, the project can't pause while we're actively developing).

- [ ] **Step 3: Commit** — `git add .github/workflows/keepalive.yml && git commit -m "ci: daily Supabase keep-alive ping"`

---

### Task 18: Cutover runbook (document only — executed on cutover night)

**Files:**
- Create: `docs/cutover-runbook.md`

- [ ] **Step 1: Write `docs/cutover-runbook.md`**

```markdown
# Cutover runbook (target: ~1-hour claim freeze)

Preconditions: parity harness green, RLS script green, walkthrough complete,
keep-alive workflow merged-ready. Decide sandbox-becomes-prod (default: yes,
this project IS prod) — if a fresh project is preferred instead, re-apply
migrations 001-005 there first and swap URL+keys in index.html + keepalive.yml.

1. [ ] Announce the freeze (IG story/GC): "GO site paused ~1 hour for an upgrade."
2. [ ] Freeze: in the LIVE sheet's Apps Script, redeploy with `submitClaim`
       returning `{ok:false, error:'closed', message:'Site upgrade in progress'}`
       (single-line change), or simply mark every GO closed in the sheet UI.
       Note what was changed so it can be restored for rollback.
3. [ ] Fresh export: Google Sheets → File → Download → .xlsx →
       overwrite `GO Manager Data.xlsx` locally (do NOT commit — gitignored).
4. [ ] `python3 db/migrate_from_xlsx.py --dry-run` → quality report clean.
5. [ ] `SUPABASE_DB_URL=… python3 db/migrate_from_xlsx.py` → zero MISMATCH.
6. [ ] `python3 db/export_snapshot.py && node tests/parity.mjs` → PARITY OK.
7. [ ] Spot-check via SQL: newest claim in the sheet exists in `claims`;
       per-GO claim counts match the export.
8. [ ] Merge: `git checkout main && git merge supabase-migration && git push`.
9. [ ] Live smoke test (~15 min, phone): landing, open biggest GO, place + delete
       a test claim (admin), My Orders, admin login, payments tab.
10. [ ] Reopen: announce claims are back.
11. [ ] Sheet afterlife: rename the spreadsheet "…(ARCHIVE — read only)";
        leave Apps Script dormant. Delete only weeks later, once confident.

Rollback (any failure in 8-9): `git revert <merge-commit> && git push` —
GitHub Pages serves the Sheets version again within ~1 min; undo step 2's
freeze. The Sheet was frozen the whole window, so no data diverged.
```

- [ ] **Step 2: Commit** — `git add docs/cutover-runbook.md && git commit -m "docs: cutover-night runbook"`

**Optional (decide with Jinghan): `beta.html`** — copy the finished `index.html` to `beta.html` on `main` (index.html untouched) for real-phone testing at the live URL before cutover night. If wanted, do this after Task 16.

---

## Self-review notes

- **Spec coverage:** §1 schema → Task 1 (with deviations 1/2/4 documented). §2 auth/RLS/RPCs → Tasks 2-4, 6, 12. §3 frontend → Tasks 9-14 (deviation 3). §4 migration script → Tasks 7-8 (sheet-name truncation handled; quality report per spec). §5 testing/cutover → Tasks 15-18. Keep-alive → Task 17. Storage/image upload → Tasks 5, 14. Success criteria: 1→Task 15, 2→Task 16, 3→Task 16 step 3, 4→Task 6, 5→Task 18.
- **Known judgment calls during execution:** exact ids/markup of the admin form fields (Tasks 12-14 name search anchors, not hard line numbers, since earlier tasks shift lines); PostgREST status codes in Task 6 (noted inline); parity canonicalization tolerances (Task 15 step 3 bounds what may be adjusted).
- Line numbers refer to the file as of commit `3e5b305`; they drift as tasks land — search anchors are given wherever a task depends on one.
