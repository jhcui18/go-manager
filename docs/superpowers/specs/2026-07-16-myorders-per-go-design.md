# My-orders Grouped Per GO — Design

**Date:** 2026-07-16
**Status:** Design approved, pending spec review

## Problem

The buyer "My orders" lookup renders **one flat table of all claims** across every
GO (`#lookup-tbody`), then a grand Total/Paid/Unpaid footer row, then **separate
per-GO pay panels** (`#lookup-pay-panels`), then a shipping panel. Claims and their
GO's payment are far apart, and the flat table repeats the GO name on every row.

## Goal

Reorganize the result area into a vertical stack of **per-GO blocks**. Each block
shows that GO's claims followed immediately by that GO's payment section (the
existing Paid/Owed/Credit summary + send-payment form). No cross-GO grand total.

## Layout

Inside `#lookup-result`, keep the header card (avatar, `#result-username`,
`#result-count`, ↻ Refresh, ← Back). Replace the single flat `.table-wrap`/table
with a new container `#lookup-go-blocks` holding the per-GO blocks. Keep
`#lookup-ship-panel` at the very bottom. `#lookup-pay-panels` is removed (its
content moves into each block).

### Per-GO block (a card)

- **Collapsible header (default expanded):** chevron · GO name · a compact
  right-side status: `Owed $Y` when owed > 0, else `Credit $Z` when credit > 0,
  else `All paid ✓` (only if the buyer has a secured claim / any payment; otherwise
  no status chip). Clicking the header toggles the body.
- **Body:**
  - **Claims table** for that GO — columns *Item · Version/Member · Qty · Price ·
    Claim · Payment · Fulfillment* (the GO column is dropped). Includes all the
    buyer's claims in that GO, Pending and Not-fulfilled included, with the same
    badges as today (`Secured`/`Pending`/`Not fulfilled`, `Paid`/`Unpaid`,
    fulfillment badge). Dropped ("Not fulfilled") rows still render greyed.
  - **Payment section** (from `goPaymentSummary(u, go_id)`): the
    `Paid $X · Owed $Y · Credit $Z` line (+ `· $P awaiting confirmation`), then:
    - `owed > 0` → the send-payment form (Method / Amount / Transaction ID / "I
      paid"), preserving the existing field ids `pay-method-${go_id}`,
      `pay-amount-${go_id}`, `pay-txid-${go_id}` and `submitGoPayment('${go_id}','${u}')`.
    - else `credit > 0` → the teal "held as credit" note.
    - else → `All paid ✓` (nothing owed and something was paid) or nothing.

### Ordering & scope

- GO blocks ordered **newest GO first** (reuse `goCreatedTs`), matching the admin
  store-orders panel. The **Shop** pseudo-GO (`go_id: 'shop'`) is its own block,
  placed last.
- A GO where the buyer has only unsecured/unpaid claims still gets a block (so they
  see those spots); its payment section shows `Owed $0` with no form.
- `#result-count` keeps its current meaning: number of active (non-"Not fulfilled")
  claims across all GOs.
- **No grand total** row.

### Collapse state

A module-level `myOrderGoOpen = {}` maps `go_id → bool`, default open (a missing
key renders expanded). Toggling flips it and shows/hides that block's body, the same
pattern as `adminOpenSI` / `storeGoOpen`.

## Shipping

`#lookup-ship-panel` and `renderShipPanel(u)` are unchanged — one cross-GO "Request
shipping" panel at the bottom that bundles all Ready + Paid items into a single
request. Splitting it per GO would break that bundling, so it stays as-is.

## Data / reuse

- `doLookup` still builds the same `rows` array (`{ go_id, go, item, detail, qty,
  price, claim, payment, fulfillment }`). Instead of rendering one table + separate
  pay panels, it **groups `rows` by `go_id`** and renders a block per group.
- The payment section reuses `goPaymentSummary` and the exact send-payment markup
  already built for the current per-GO pay panels (same field ids and handlers), so
  submitting a payment is unchanged.
- Totals math previously in `doLookup` (grandTotal/paidTotal/unpaidTotal) is
  removed; per-GO figures come from `goPaymentSummary`.

## Backend impact

None. Pure frontend re-layout of the lookup result. No redeploy.

## Out of scope (YAGNI)

- Per-GO shipping requests (shipping stays cross-GO).
- Cross-GO grand total / account summary.
- Changing claim classification, payment, or credit logic (reused as-is).
