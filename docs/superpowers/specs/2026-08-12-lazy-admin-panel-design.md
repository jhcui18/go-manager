# Lazy Admin Panel — Design

**Date:** 2026-08-12
**Status:** Design — pending user review

## Problem

The admin page loads everything at login: `syncFromBackend` (admin branch) fires an
11-call batch whose heaviest member is `getAllGOs` — **~2.2 MB, every claim in every GO**.
Measured ~9s of network alone; ~20s end-to-end on the admin's device (download + JSON parse
+ rebuilding every GO's sets + render), and under Apps Script throttling it intermittently
**fails outright** ("Some data could not be refreshed — showing the latest that loaded"),
leaving the admin on stale/partial data. This is not just slow; at 2.2 MB it is fragile.

Joiner-side loads were already made lazy (landing = `getGOsList`; opening a GO = cached
`getGOBoard`). The admin path was deliberately left alone — but it is now the worst
remaining experience, so it gets the same treatment.

## Goal

Admin login loads only light, reliable data and renders in ~1s. Each admin area fetches its
own data when opened. No 2.2 MB up-front read, so the "could not sync" failure disappears.

**Frontend-only. No new backend endpoints, no redeploy** — every call already exists
(`getGOsList`, `getPayments`, `getGOBoard`, `getListings`, `getShopOrders`,
`getStoreOrders`, `getShipping`).

## Layout: sub-tabs

The admin home gets a tab bar under the "Admin" title. One section on screen at a time;
tapping a tab loads its data the first time. Reduces the long mobile scroll and gives each
table full width.

```
Admin                          [+ New GO]
┌───────┬──────┬───────┬──────────┬──────────┐
│ GOs●  │ Shop │ Store │ Payments │ Shipping │
└───────┴──────┴───────┴──────────┴──────────┘
```

- **GOs** (default) — Active group orders list.
- **Shop** — Shop listings + Shop orders (both shop-related, grouped).
- **Store** — My store orders.
- **Payments** — Pending payment proofs.
- **Shipping** — Shipping queue.

## Load behavior

**At login** (`syncFromBackend`, admin branch) — drop `getAllGOs` and the rest of the
11-call batch. Load instead:
- **Blocking:** `getGOsList` (GO + sub-item metadata, no claims) → renders the GOs tab
  instantly. `allGOs` is rebuilt from metadata only (no `sets`/`claims`).
- **Background (non-blocking, after first render):** `getPayments` → populates
  `paymentProofs`, which drives (a) the `"$X collected"` line on each GO card and (b) the
  Payments tab. A failure here degrades only those two spots, never the whole page.

**Per tab, on first open** (guarded by a `…TabLoaded` flag, mirroring the buyer
`loadShopListings` pattern):
- **Shop** → `getListings` + `getShopOrders`.
- **Store** → `getStoreOrders`.
- **Payments** → already loaded by the background `getPayments`; just render (no refetch).
- **Shipping** → `getShipping`.

**Opening a GO's Manage view** (`openGODetail`, now async) → load that GO's claims + flags
via the cached `getGOBoard` (reusing/ generalizing `loadGOClaims` so it also runs for admin),
rebuild that GO in `allGOs`, then `renderDetailContent`. The ↺ button (`refreshCurrentGO`)
re-fetches just that one GO, not a full sync.

## GO card content (GOs tab)

Cards show: name, type badge, open/closed, and **`"$X collected"`** (from the background
`getPayments`). The claim counts (`"N claims · M secured"`) and **`"of $Y expected"`** are
**removed from the card** (they need every GO's claims) and instead shown in the GO's Manage
view, where that GO's claims are loaded. `renderAdminGOList` therefore stops calling
`goExpected(go)` and the per-sub-item count reducers; it keeps only the `collected` sum
(`paymentProofs` filtered by `go_id` + `status==='confirmed'`).

## The one risky integration: confirming a payment

`confirmPayment(id)` calls `paymentOwedUnits(p.username, p.go_id)`, which reads
`allGOs[p.go_id]`'s `sets`/`claims` to pick which items to mark paid. With lazy loading those
claims may not be present. Fix: **make `confirmPayment` async** — before computing, ensure the
target GO's data is loaded:
- normal GO → `await loadGOClaims(p.go_id)` (cached `getGOBoard`);
- `p.go_id === 'shop'` → ensure `shopOrders` loaded (open/await the Shop data).

Then proceed exactly as today. `applyConfirmPayment` is unchanged (it already marks by
`claim_id`/`order_id`, and the backend `updatePayment` marks server-side by those ids).

## Other admin actions

The admin's own writes already bust the relevant `getGOBoard` cache (added in the caching
change), so reopening a GO after securing/closing/editing shows fresh data. Actions that read
across all GOs and are NOT covered by a single loaded GO:
- **"same txid on other GOs" hint** in the payment-proofs row — uses `paymentProofs` only
  (loaded). Fine.
- **Joiner list / GC tracker** live inside a GO's Manage view (per-GO), so they render from
  that GO's loaded claims. Fine.

No admin feature reads all claims across all GOs *except* the removed home-card counts/expected.

## Graceful degradation

If `getGOsList` fails at login, fall back to `getAllGOs` (the existing buyer fallback already
does this) so the admin still gets data the old way. Each tab's fetch and the background
`getPayments` fail independently with a small inline message, never blocking the page.

## Out of scope

- Backend changes (none needed).
- The eventual database migration (separate off-season project) — this is the interim that
  makes admin usable this season.
- Changing the GO Manage view's internals (only its data now arrives lazily).

## Testing

- **JS-parse** all `<script>` blocks after each change.
- **Login:** admin lands on the GOs tab rendered from `getGOsList`; no `getAllGOs` at login
  (verify in Network); `"$X collected"` fills in once `getPayments` returns; no "could not
  sync" toast.
- **Tabs:** first open of Shop/Store/Shipping triggers exactly one fetch; second open
  refetches nothing.
- **Manage:** opening a GO loads its claims via `getGOBoard` and shows counts + expected;
  ↺ refreshes just that GO.
- **Confirm payment:** confirming a proof for a GO whose Manage view was never opened still
  loads that GO's claims first and marks the correct items paid (the money-critical path).
- **Fallback:** simulate `getGOsList` missing → admin falls back to `getAllGOs`.
