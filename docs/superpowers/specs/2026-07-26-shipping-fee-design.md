# Shipping Fee (EMS + Live Domestic Quote) — Design

**Date:** 2026-07-26
**Status:** Design approved, pending spec review

## Problem

When a joiner submits a shipping request they see no cost. The admin only enters
EMS/domestic fees manually in the queue *after* submission. We want the joiner to
see an accurate up-front **total shipping** (international EMS + US domestic) at
submit time, computed automatically, matching what the admin actually pays.

## Goal

1. Capture per-item shipping inputs (EMS rate; weight + dimensions) once, when the
   admin marks an item **Ready**.
2. At submit, combine the joiner's chosen items into **one package**, get a **live
   USPS rate** (via Shippo) for the domestic leg, add the EMS subtotal, and show the
   joiner the total. The admin can still override in the queue.

## Key decisions (from brainstorming)

- **Domestic pricing = live Shippo rate quote** (not a baked table). Shippo returns
  USPS commercial rates (same pricing Pirate Ship uses); **rate quotes are free**
  (you only pay when buying a label, which the admin still does on Pirate Ship).
- **One combined package per shipment**, not per-item. Shipping is priced per
  package. Combined weight is additive; combined box dimensions are an approximation
  (the one unavoidable estimate — accepted, "it evens out," admin overrides oddballs).
- **EMS applies to GO claims only** (photocards + albums/merch). **Shop/store orders
  get no EMS** but still contribute weight/dims to the combined package.
- **Origin ZIP = 02021.**
- **Stamp special case:** photocard-only shipments of **≤4 cards → flat $2** (no API
  call).
- API key lives **server-side** (Apps Script Script Properties). The frontend never
  holds it; the backend proxies the Shippo call. Quote is a **live round-trip at
  submit**, with a fallback when Shippo is unavailable.

## Data model (backend — REQUIRES REDEPLOY)

Per-item shipping inputs are stored **per claim / per shop order** (not on the
sub-item), remembered via **sibling reuse** (below). This reuses the existing
`updateClaim` / `updateShopOrder` write paths — no sub-item schema change.

- **`joiners` (claims) sheet** — new columns (auto-migrated by `ensureSheet`):
  `ems_fee` (per-unit EMS rate), `weight_oz`, `length_in`, `width_in`, `height_in`,
  `media_flag` (`'1'` if Media-Mail-eligible, else '').
- **`shop_orders` sheet** — new columns: `weight_oz`, `length_in`, `width_in`,
  `height_in`. (No `ems_fee`, no `media_flag`.)
- **`shipping` request** keeps its existing `ems_fee` / `dom_fee` / `total_fee` /
  `card_count`; additionally stores `ship_service` (the chosen USPS service token,
  e.g. `usps_ground_advantage`) for the admin's reference.
- `updateClaim` writes the new claim columns when present; `updateShopOrder` writes
  the new order columns when present. Getters return them automatically
  (`sheetToObjects`).

## Capture at mark-Ready (frontend)

At each choke point where an item advances **to `'Ready'`** — `advanceSetFulfill`,
`advanceFCFSFulfill`, `advanceBatchFulfill` (GO claims), and `advanceShopFulfill`
(shop orders) — resolve the item's shipping inputs:

1. **Sibling reuse (the "ask once" memory):** look for another claim in the **same
   sub-item** (or another shop order for the **same listing**) that already has
   `weight_oz` set. If found, **copy its** `ems_fee` / `weight_oz` / dims /
   `media_flag` silently. This is what makes it "ask once per sub-item/listing."
2. **Photocard default:** if none found and the item is a photocard (set-based or
   batch member claim), default silently to `ems_fee = 0.50`,
   `weight_oz = 0.5`, dims = one card in a sleeve (`3.5 × 2.5 × 0.02`),
   `media_flag = ''`. (Photocards never prompt.)
3. **Prompt otherwise** (albums, merch, shop orders): a small modal asks for
   **EMS per unit** (pre-filled `0.50`; shop orders skip EMS → forced 0),
   **weight (oz)**, **length/width/height (in)**, and a **"Media Mail eligible"**
   checkbox (claims only). Store on this item.
4. Persist via `updateClaim` / `updateShopOrder`. Marking Ready proceeds only after
   the inputs are resolved (cancel → stay at previous fulfillment).

## Submit — combine + quote (frontend + backend)

`shipEligibleItems` is extended so each returned item carries `ems`, `weight_oz`,
dims, `media`, `qty`, and `is_photocard`.

`submitShippingRequest(username)` (already builds from the **checked** items):

Determine the case from the checked items (`is_photocard` claim = card; album =
media-flagged claim; else merch/shop):

1. **Card-only, ≤ 4 cards (stamp):** `dom_fee = 2.00`, `ship_service = 'stamp'`,
   **skip the API**.
2. **Card-only, 5–49 cards (fixed 9×7 mailer):** don't stack — use the known mailer:
   `length = 9`, `width = 7`, `height = ceil(Σ card heights × HEIGHT_PAD)` (min 0.5"),
   `weight_oz = ceil(Σ card weights) + CARD_PACKAGING_OZ` where
   `CARD_PACKAGING_OZ = 2` (bubble mailer + freebies). Then **quote** (step 4).
3. **Everything else** (any album/merch/shop item, or ≥ 50 cards) — build the
   combined parcel with the **padded stacking heuristic** so the quote errs high
   (packing room, never under-charges):
   - `weight_oz = ceil(Σ (item.weight_oz × qty) + PACKAGING_BASE_OZ)`
     (`PACKAGING_BASE_OZ = 1`).
   - `length = max(item lengths) + DIM_MARGIN_IN`,
     `width  = max(item widths)  + DIM_MARGIN_IN`,
     `height = Σ (item.height_in × qty) × HEIGHT_PAD`,
     each **rounded up to the next whole inch**, floored to a mailer minimum.
     Constants: `DIM_MARGIN_IN = 1`, `HEIGHT_PAD = 1.2`.
   - **Album-only → Media Mail:** if every checked item is an album (media-flagged
     claim) with no cards/merch/shop items, set `media_only = true` so the quote
     considers USPS Media Mail (usually cheapest for books).
4. **Quote:** POST to new backend action `quoteShipping`
   `{ from_zip:'02021', to_zip, to_state, parcel:{weight_oz,length_in,width_in,height_in}, media_only }`.
   Backend returns `{ ok, domestic, service }` (cheapest eligible USPS rate) or
   `{ ok:false }`.
5. **Apply:** `ems_fee = Σ (item.ems × qty)` (photocard/claim items only);
   `dom_fee = domestic` (or blank on failure); `total_fee = ems_fee + dom_fee`.
   Store `ship_service`.
6. **Show the joiner** a confirmation before saving: EMS subtotal, domestic, total,
   plus the **estimate disclaimer** (below). On quote failure show "Domestic
   shipping will be calculated by the admin" and still allow submit (dom_fee blank).

### Joiner-facing disclaimer

Wherever the domestic estimate is shown to the joiner (ship panel + submit
confirmation), display this note:

> *Domestic shipping is an estimate. If the actual cost is lower, I'll refund the
> difference; if it's higher, I'll ask for the small extra.*

The joiner needs a destination **ZIP** for the quote (the address form already
collects it) — validate ZIP present before quoting; if missing, treat as failure
(admin-calculated).

## Backend — Shippo proxy (`quoteShipping`)

New doPost action `quoteShipping(data)`:

- Read `SHIPPO_TOKEN` from `PropertiesService.getScriptProperties()`.
- `UrlFetchApp.fetch('https://api.goshippo.com/shipments/', {method:'post',
  contentType:'application/json', headers:{Authorization:'ShippoToken '+token},
  muteHttpExceptions:true, payload: JSON.stringify({
    address_from:{zip:data.from_zip, country:'US'},
    address_to:{zip:data.to_zip, state:data.to_state, country:'US'},
    parcels:[{length:data.parcel.length_in, width:data.parcel.width_in,
      height:data.parcel.height_in, distance_unit:'in',
      weight:data.parcel.weight_oz, mass_unit:'oz'}],
    async:false })})`.
- From `rates[]`, keep USPS rates whose `servicelevel.token` is
  `usps_ground_advantage`, plus `usps_media_mail` **only if** `data.media_only`.
  Return the **cheapest** `{ domestic: parseFloat(amount), service: token }`.
- Any error / no rates → `{ ok:false }`. Never throw to the caller.

## Admin shipping queue

- The request's `ems_fee` and `dom_fee` are **pre-filled** from submit (editable,
  as today) so the admin can override oddball/combined shipments or fill in a
  quote that failed. `ship_service` shown read-only for reference. Total and Mark
  shipped unchanged.

## Setup (one-time, done by the admin)

1. Create a Shippo account; get the **test** token, then the **live** token.
2. In the Apps Script project: **Project Settings → Script Properties** → add
   `SHIPPO_TOKEN` = the token. (Start with the test token so the dev side can
   verify, then swap to live.)
3. Redeploy the backend.

## Error handling & fallback

- Quote failure (Shippo down, timeout, no ZIP, no rates) → domestic shown as
  "calculated by admin"; submit still succeeds with `dom_fee` blank; admin fills in
  the queue. Submit is **never blocked** by the API.
- Mark-Ready prompt cancelled → item stays at its previous fulfillment; nothing
  persisted.

## Out of scope (YAGNI)

- Buying labels / printing postage through the app (admin keeps using Pirate Ship).
- Address-to-address label automation.
- Multi-package splitting of one shipment.
- Per-zone baked rate tables (superseded by the live quote).
- Historical items already Ready before this feature: blank shipping inputs
  (EMS 0, no dims) until re-Readied or overridden — not backfilled automatically.

## Testing

- **Backend `quoteShipping`:** with the test token, verify a known shipment
  (02021 → 36360, `10 × 7.5 × 2`, `16 oz`) returns a USPS Ground Advantage rate in
  the expected range (~$9 cubic) and that `usps_media_mail` appears only when
  `media_only`. Verify a bad/empty response yields `{ ok:false }`.
- **Frontend combine:** Node logic check of the parcel builder (weight sum +
  packaging, stacking dims, media_only detection) and the ≤4-card stamp branch.
- **JS-parse** both files. **`node --check`** the backend copy.
- **Manual:** mark a photocard, an album (prompt), and a shop order Ready; confirm
  sibling reuse (second unit no prompt); submit a mixed shipment and see EMS +
  domestic + total; simulate a quote failure and confirm submit still works and the
  admin can fill the fee.

## Redeploy note

New `quoteShipping` action + new columns on `joiners` and `shop_orders`
(auto-migrated by `ensureSheet` on bootstrap) require redeploying
`go-manager-backend.gs`, plus the one-time `SHIPPO_TOKEN` Script Property.

## Suggested phasing (for the implementation plan)

1. **EMS only** (no API): capture EMS at mark-Ready (sibling reuse + photocard
   default + prompt), EMS subtotal at submit, admin pre-fill. Ships value quickly.
2. **Weight/dims capture** at mark-Ready.
3. **Domestic live quote** (Shippo proxy + combine + submit confirmation + fallback).
