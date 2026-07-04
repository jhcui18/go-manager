# Shop Listing Variants — Design

Date: 2026-07-03
App: GO Manager (`index.html` + `go-manager-backend.gs`)
Builds on: `docs/superpowers/specs/2026-06-30-shop-feature-design.md`

## Goal

Let a single Shop listing offer named **variants** (album versions, member versions,
etc.), each with its own stock, so buyers pick a variant when ordering. Price and
photo stay at the listing level. Simple (single-quantity) listings still work — a
listing is **either** simple **or** variant-based.

## Decisions (locked)

- **Per-variant:** name + stock only. **Shared across the listing:** price, photo,
  category, note.
- **One variant per order:** the buyer taps one variant and picks a quantity
  (capped at that variant's stock), then places the order — consistent with the
  current Shop flow. Multiple variants = multiple orders.
- **Either/or:** if the admin enters variants, stock is per-variant (the single
  quantity field is not used); if no variants, it's a simple single-quantity
  listing (unchanged).
- **Sold out:** a variant greys out at 0; the whole listing shows "Sold out" only
  when every variant is 0.

## Data model

### `listings` sheet — add one column
`... , qty, variants, note, status, created_at`

- `variants`: JSON array `[{"name":"Ver A","qty":2},{"name":"Ver B","qty":1}]`, or
  empty/`[]` for a simple listing.
- `qty` (existing): used only for simple listings. For variant listings it's
  ignored (source of truth is `variants`).

### `shop_orders` sheet — add one column
`... , qty, variant, unit_price, ...`

- `variant`: the chosen variant name (empty for simple-listing orders).

## Backend (`go-manager-backend.gs`)

- `bootstrapSheets`: add `variants` to `listings` headers and `variant` to
  `shop_orders` headers.
- `createListing` / `updateListing`: accept and persist `variants` (JSON string).
- `placeShopOrder(data)` — variant-aware stock guard:
  - If `data.variant` is set: parse the listing's `variants` JSON, find the entry
    by name; if its `qty >= requested`, decrement it, write the JSON back, and
    append the order with `variant` set. Else return `{ ok:false, error:'oversold',
    available:<n> }`.
  - If no `data.variant`: existing single-`qty` behavior (simple listing).
- Order row now includes the `variant` column.

**Needs a redeploy.**

## Frontend (`index.html`)

- **State:** each listing object carries `variants` (parsed array). `getListings`
  load parses the JSON.
- **Admin listing form** (`openListingModal` / `saveListing`): add a **Variants**
  input — a textarea, one per line as `Name, stock` (e.g. `Ver A, 2`). If any lines
  are present, hide/ignore the single Quantity field and send `variants` (parsed to
  the JSON array); otherwise send a simple `qty` as today. Editing shows existing
  variants back in the textarea.
- **Shop card** (`renderShopPage`): show total remaining = sum of variant stock (or
  `qty` for simple); "Sold out" when total is 0.
- **Order view** (`openShopListing`):
  - Variant listing → show variant tiles, each labeled `Name · N left`; tapping a
    variant selects it (0-stock variants disabled). A quantity stepper capped at the
    selected variant's stock. Place order submits the chosen `variant` + qty.
  - Simple listing → current quantity stepper (unchanged).
- **submitShopOrder:** include `variant` when a variant listing.
- **My orders** shop rows: show `listing_name — variant` when present.
- **Admin Shop orders table:** add the variant to the Item column (e.g.
  `Album — Ver A`).

## Backward compatibility

Existing simple listings have empty `variants` → behave exactly as now. The new
column defaults to empty. No migration needed beyond the header add (handled by
`bootstrapSheets` / the create/update writes).

## Out of scope

- Per-variant price or photo (shared per listing).
- Picking multiple variants in one order (one variant per order).
- Variant-level notes.

## Edge cases

- **All variants 0:** listing shows "Sold out", order button disabled.
- **Variant renamed after orders exist:** past orders keep their stored variant
  name; only the listing's current variant list changes.
- **Oversell race:** server-side re-check of the specific variant's stock in
  `placeShopOrder` returns `oversold` for the loser.
- **Malformed variant line in the textarea** (`Name` with no comma/stock): the
  parser splits on the last comma and requires a numeric stock; a line without a
  valid trailing number is **ignored** (dropped).
