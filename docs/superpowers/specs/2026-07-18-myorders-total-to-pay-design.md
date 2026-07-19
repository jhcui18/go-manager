# My-orders Combined "Total to Pay" — Design

**Date:** 2026-07-18
**Status:** Design approved, pending spec review

## Problem

My orders shows per-GO Paid/Owed/Credit but no combined figure. Buyers who pay
for multiple GOs in one transfer (paste the same transaction id on each) have no
single number telling them how much to send.

## Goal

Add a summary card at the top of the My-orders result showing the **total owed
across all the buyer's GOs**, so they can send one combined transfer.

## Design

In `doLookup`, when rendering the per-GO blocks into `#lookup-go-blocks`:

- Compute `totalOwed = sum over goList of goPaymentSummary(u, g.go_id).owed`.
- When `totalOwed > 0`, prepend a summary card **above** the per-GO blocks:
  > **Total to pay across all GOs: $X**
  > You can send this in one transfer — just paste the same transaction ID on each
  > GO's payment below.
- When `totalOwed === 0`, show no summary card (nothing to prompt).
- The per-GO blocks are unchanged; this only prepends the combined line.

## Scope / reuse

- Reuses `goPaymentSummary` (already the source of each GO's `owed`). No new totals
  logic beyond the sum.
- Only the `owed` total is shown (not paid/credit), per decision.
- Shop pseudo-GO is included in the sum like any other GO (its `owed` comes from
  `goPaymentSummary('shop')`).

## Backend impact

None. Frontend-only, no redeploy.

## Out of scope

- Combined paid/credit totals.
- Any cross-GO payment mechanics (buyers still submit per-GO with a shared txid).
