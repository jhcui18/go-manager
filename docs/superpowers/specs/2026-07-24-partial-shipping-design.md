# Partial Shipping — Buyer Picks Which Items to Ship — Design

**Date:** 2026-07-24
**Status:** Design approved, pending spec review

## Problem

The buyer "Request shipping" panel bundles **all** their Paid + Ready items into one
request — they can't ship some now and hold the rest (e.g. wait to consolidate more
items). There's no way to choose a subset.

## Goal

Let the joiner select **which** of their ready items to include in a shipping
request via a checkbox per item (default all checked). Unchecked items stay
available for a later request.

## Behavior

- **`renderShipPanel(username)`**: instead of a read-only bullet list, render each
  eligible item as a row with a **checkbox** (id keyed on the item id), **checked by
  default**. Keep the address form + submit button as-is.
- **`submitShippingRequest(username)`**: build the request from only the **checked**
  items (read the checkboxes), not all eligible items.
  - If **no** item is checked → toast "Pick at least one item to ship." and stop.
  - `card_count` = number of checked items.
- **Unchecked items remain available**: `shipEligibleItems` already excludes only
  items present in a *submitted* request's `items`, so anything left unchecked
  reappears in the panel next time. No change needed there.

## Scope / reuse

- Frontend-only. No backend change (the request already carries an `items` array;
  we just submit a subset). The admin queue, fees, address, and mark-shipped are
  unchanged.
- The checkbox row shows the same item label as today.

## Out of scope (YAGNI)

- Admin-side item selection within a request.
- Per-item shipping fees.
- Splitting an already-submitted request.

## Backend impact

None.
