# Supabase Migration — Design Spec

**Date:** 2026-08-13
**Status:** Approved design, pre-implementation
**Branch:** `supabase-migration` (never merged to `main` until cutover night)

## Goal

Replace the Google Sheets + Apps Script backend with a Supabase (Postgres) database,
eliminating the structural performance ceiling (whole-sheet scans, ~30-execution
throttling, 2.2MB admin reads) and the data-integrity gaps (no constraints, no
transactions, race-prone slot claims, unauthenticated write API).

The frontend stays a single `index.html` on GitHub Pages, no build step.

## Decisions (agreed with Jinghan)

| Decision | Choice |
|---|---|
| Platform | Supabase free tier, US-East region. Jinghan creates the account/project herself and pastes URL + anon key; Claude never handles credentials. |
| Cutover | Big-bang with ~1-hour claim freeze — but only after the DB version is **fully built and tested in parallel**. Sheets version stays live and untouched until then. |
| Schema | Fully normalized ("real website standard"), not a 1:1 sheet mirror. |
| Admin auth | Real Supabase email+password login for the single admin; replaces the frontend-only password gate. |
| Joiners | Stay anonymous (IG handle as self-reported identity); no accounts. |
| Dev data | Jinghan exports the current Google Sheet as `.xlsx`; all build/test work runs against that snapshot in a sandbox. **No touching the live Sheet, Apps Script, or website during the build.** |
| Free-tier pause | Mitigated by a daily keep-alive ping (GitHub Actions cron making one trivial query). Manual dashboard Restore is the fallback; $25/mo Pro is the opt-out if babysitting ever annoys. |
| Item images | Supabase Storage upload (admin-only write, public read, client-side compression to ~150KB) becomes the primary path; paste-a-URL field remains. `image_url` column stores either. |
| Sheets afterlife | Kept frozen as a read-only archive after cutover. Apps Script left dormant, deleted only once confident. |

## §1 Schema

UUIDs for PKs (`gen_random_uuid()`), `legacy_id text` on every migrated table for
traceability to the Sheets original. All timestamps `timestamptz`, money
`numeric(10,2)`, usernames `citext` (requires `create extension citext`).
Schema lives in numbered SQL migration files in `db/migrations/`, committed to git.

### Enums

- `go_type`: `photocard | album | merch`
- `go_status`: `open | closed`
- `sub_item_kind`: `set | versioned | single | merch` (`set` covers today's photocard/member/member-set POBs)
- `order_mode`: `set | batch` (retires the `minSecure = -N` sentinel; `batch_size int` holds N)
- `set_status`: `open | secured`
- `claim_status`: `pending | secured | dropped`
- `payment_status` (on claims): `unpaid | paid`
- `payment_state` (on payments): `pending | confirmed | rejected`

### Tables

**gos** — `id`, `legacy_id`, `name text not null`, `artist text` (real column;
seeded from the name-prefix convention at migration, editable in admin UI),
`type go_type`, `status go_status default 'open'`, `deadline timestamptz`,
`payment_deadline timestamptz`, `min_secure int default 7`, `created_at`, `updated_at`.

**sub_items** — `id`, `legacy_id`, `go_id → gos on delete cascade`, `name`,
`kind sub_item_kind`, `order_mode order_mode default 'set'`, `batch_size int`,
`price`, `ot_price`, `min_secure int` (per-item override, nullable),
`image_url`, `position int`, `closed bool default false`, `deadline timestamptz`,
`pay_due timestamptz`, `created_at`.
Absorbs the `closed_subitems`, `subitem_deadlines`, `subitem_payment_due` flag sheets.

**members** — `id`, `sub_item_id → sub_items cascade`, `name text`, `position int`,
UNIQUE `(sub_item_id, name)`.
**versions** — same shape. Two tables (not one generic options table) because members
participate in set/slot mechanics with slot-uniqueness while versions are qty-only;
merging would force conditional constraints Postgres can't express declaratively.

**sets** — `id`, `sub_item_id → sub_items cascade`, `set_no int`,
`status set_status default 'open'`, `created_at`, UNIQUE `(sub_item_id, set_no)`.
Sets become real rows; `buildSetsFromClaims` and the `secured_sets` sheet retire.

**claims** — `id`, `legacy_id`, `sub_item_id → sub_items on delete restrict`
(blocks deleting a POB with live claims), `username citext not null`, `email text`,
`set_id → sets` (null for versioned/batch/merch), `member_id → members`,
`version_id → versions`, `is_ot bool default false`, `qty int check (qty > 0) default 1`,
`assigned_version text`, `status claim_status default 'pending'`,
`payment_status payment_status default 'unpaid'`, `fulfillment text`,
`created_at`, `updated_at`.
**Partial unique index** `(set_id, member_id) where set_id is not null and
member_id is not null and status <> 'dropped'` — slot collisions structurally impossible.
Indexes: `sub_item_id`, `username`.

**payments** — `id`, `legacy_id`, `username citext`, `go_id → gos`, `amount`,
`method text` (includes `'credit'` — the existing credit-ledger pattern, formalized),
`transaction_id`, `proof_url`, `email`, `status payment_state default 'pending'`,
`note`, `created_at`. Index: `username`, `go_id`.

**gc_members** — `(go_id → gos cascade, username citext)`, composite PK. (Was `gc_added`.)

**shipping_requests** — `id`, `legacy_id`, `username citext`, `full_name`,
`address1`, `address2`, `city`, `state`, `postal`, `country`, `notes`, `email`,
`ems_fee`, `dom_fee`, `total_fee`, `shipped bool default false`, `created_at`.
Planned-future (not built now): `label_url`, `tracking_number`, `label_cost` for Shippo.
**shipping_request_items** — `id`, `request_id → shipping_requests cascade`,
`go_id`, `description text`, `qty int`. Replaces the `items` JSON blob + `go_ids` CSV;
`card_count` becomes derived.

**listings** — `id`, `legacy_id`, `name`, `category`, `price`, `image_url`, `qty int`
(for variant-less listings), `note`, `status`, `created_at`.
**listing_variants** — `id`, `listing_id → listings cascade`, `name`, `qty int`.

**shop_orders** — `id`, `legacy_id`, `listing_id → listings restrict`,
`variant_id → listing_variants`, `username citext`, `email`, `qty check (qty > 0)`,
`unit_price`, `payment_status`, `fulfillment`, `created_at`, `updated_at`.

**store_orders** — `id`, `legacy_id`, `go_id → gos`, `sub_item_id → sub_items`,
`store text`, `album_version`, `qty`, `unit_cost`, `status`, `notes`,
`created_at`, `updated_at`. (Admin's own orders placed with stores/proxies.)

## §2 Auth & RLS

Two identities:

1. **anon** (joiners, via published anon key) —
   - SELECT: `gos`, `sub_items`, `members`, `versions`, `sets`, `claims`,
     `listings`, `listing_variants`, and a **`shipping_status` view**
     (`username, ems_fee, dom_fee, total_fee, shipped, created_at` — **no address columns**;
     closes today's open-addresses hole where `getShipping` exposes every address).
   - INSERT: none directly — all anon writes go through RPCs (below).
   - UPDATE/DELETE: none, anywhere.
2. **authenticated admin** (Jinghan's Supabase email+password account) — full CRUD on
   all tables via RLS policies on the authenticated role. Single admin; no role matrix.
   Login form replaces the `kpop2026` prompt; session persists in browser.

**RPCs (Postgres functions, SECURITY DEFINER, callable by anon where noted):**

- `submit_claim` (anon) — validates GO open + POB open + slot availability; finds-or-creates
  the target set; inserts claim(s) atomically. Unique slot index is the backstop.
  Status fields forced to `pending`/`unpaid` regardless of input.
- `submit_payment` (anon) — inserts payment with `status='pending'` forced.
- `submit_shipping` (anon) — inserts request + items in one transaction.
- `place_shop_order` (anon) — validates stock, decrements, inserts order atomically.
- `apply_credit` / `reverse_credit` (admin-only) — the cross-GO credit ledger moves.
- `secure_set` / `unsecure_set` (admin-only) — set status + claim statuses together.

Multi-row admin edits (`updateGO`-style sub-item rewrites) also become RPCs so the
LockService pattern has a proper transactional successor.

## §3 Frontend changes

- **Unchanged:** all render/UI code, pages, admin panels, artist grouping. Single-file
  `index.html`, GitHub Pages, no build step.
- **New dependency:** `supabase-js` UMD from CDN `<script>` tag.
- **Swap layer:** the 71 `apiGet`/`apiPost` call sites route through a new `db.*` module.
  Normalized rows are mapped into the exact in-memory shapes the render code already
  consumes (member rows → `si.members` names array; sets+claims → `si.sets[].slots` map).
  Rewrite is confined to ~15 loader/builder functions (`syncFromBackend`, `loadGOClaims`,
  `buildSetsFromClaims` retires, flag-map lookups become columns).
- **Deleted:** 20s-timeout + jittered-retry machinery, `getGOBoard` cache workaround,
  API-URL settings field, and (post-cutover) `go-manager-backend.gs`.
- **Admin login:** email+password form via supabase-js auth.
- **Admin image upload:** New/Edit GO image field gains upload-to-Storage
  (client-side downscale to ~150KB before upload); URL-paste input remains.
- **Config:** `SUPABASE_URL` + anon key constants replace `DEFAULT_API_URL`.
- **Expected performance:** landing = 1 small query; biggest-GO open = a handful of
  indexed queries, ~100–300ms each; My Orders = indexed username lookups;
  admin full load sub-second (vs ~9s).

## §4 Migration script

`db/migrate_from_xlsx.py` — standalone, reads the exported `.xlsx`, writes to Supabase.
Never touches the Sheet or the live app.

Transforms: JSON member/version arrays → rows · `set_num` + `secured_sets` → `sets`
rows with claims re-pointed by id · `minSecure=-N` → `order_mode='batch', batch_size=N` ·
flag sheets → `sub_items` columns · shipping `items` JSON + `go_ids` CSV → child rows ·
listings `variants` JSON → `listing_variants` · usernames trimmed/`@`-stripped once ·
artist parsed from name prefix into `gos.artist` · original ids → `legacy_id` ·
string dates → timestamptz · empty strings → NULL.

**Data-quality report** at the end: orphan claims, duplicate slots (would violate the
unique index), unknown member names, unparseable dates — each listed with its row for
a human decision (fix / skip / keep). No silent garbage imports.

**Re-runnable:** wipe-and-reload semantics; run freely against the sandbox, once more
against production on cutover night with a fresh export.

## §5 Testing & cutover

Testing (all sandbox, in order):
1. Migration validation — quality report clean or explicitly resolved; per-table row
   counts checked against the Sheet.
2. **Parity harness** — same GO loaded through old shape-builders (from snapshot) and
   new `db.*` layer; asserts identical boards (sets, fills, secured flags, claim totals)
   for every GO in history.
3. Full manual walkthrough on the branch build — joiner: set slot / batch / version /
   OT / merch claim, shop order, payment, shipping, My Orders; admin: login, create/edit
   GO, secure/unsecure, confirm payment, credit, store orders, shipping fees. Headless
   phone-width screenshots.
4. Optional `beta.html` published for real-phone testing (separate URL, `index.html`
   untouched).

Cutover night (~1-hour freeze): announce pause → fresh export → migration to prod
project → row counts + spot-checks → flip frontend keys, merge branch, push `main` →
15-min live smoke test → reopen claims. Sheet kept frozen as archive.

**Rollback:** `git revert` + push restores the Sheets site exactly (Sheet was frozen
during the window, so no divergence possible).

## Future capabilities (documented, not built)

- **Shippo labels:** Edge Function `create-label` holding the Shippo key; admin-session
  gated; writes `label_url`/`tracking_number` back. Address columns already structured.
- **Email notifications:** Edge Function + provider (e.g. Resend free tier); triggered
  by admin button, database webhook (e.g. set secured), or `pg_cron` digests. `email`
  columns already collected on claims/shipping.

## Out of scope

- Joiner accounts/login; multi-admin roles.
- Realtime subscriptions (Supabase supports them; not needed for launch).
- The parked wallet model (payments stay per-GO with credit rows).
- Any change to the live Sheets version besides the final cutover.

## Success criteria

1. Parity harness passes on the full historical dataset.
2. All §5.3 manual flows work on sandbox.
3. GO-open and admin-login wall-clock each under 1s on the branch build.
4. RLS verified: anon cannot update/delete anything, cannot read addresses,
   cannot insert non-pending statuses (checked with direct API calls, not just the UI).
5. Cutover completes inside the freeze window with rollback never needed — or rollback
   restores the old site in under 5 minutes.
