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
