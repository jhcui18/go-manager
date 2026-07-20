# Per-GO Payment Deadline — Design

**Date:** 2026-07-19
**Status:** Design approved, pending spec review

## Problem

The admin announces a payment deadline (in the group chat) but there's nowhere on
the site to show it. Buyers who owe should see "pay by \<date\>" for that GO.

## Goal

A new optional per-GO **payment deadline** the admin sets in Create/Edit GO, stored
in the backend, and shown to buyers in My orders — **only in GO blocks where they
still owe** something.

## Backend (Apps Script — REQUIRES REDEPLOY)

Add a `payment_deadline` column to the `_gos` sheet (`ensureSheet` auto-appends it
to existing sheets on bootstrap).

- `bootstrapSheets`: append `'payment_deadline'` to the `SHEET_GOS` header array
  (at the end, after `created_at`).
- `createGO`: append `data.payment_deadline || ''` as the final value of the row
  (matching the new last column).
- `updateGO`: set `payment_deadline` when provided — guard the column index:
  `const pdCol = headers.indexOf('payment_deadline'); if (pdCol !== -1 &&
  data.payment_deadline !== undefined) goSheet.getRange(i+1,
  pdCol+1).setValue(data.payment_deadline);` (use `!== undefined` so it can be
  cleared, unlike the truthy `if (data.deadline)` pattern).
- `getAllGOs`: no change — `sheetToObjects` already returns every column, so
  `payment_deadline` comes through.

## Frontend

The GO object carries `paymentDeadline` (camelCase, date string `YYYY-MM-DD` or '').

- **Create GO** (`createGO`): add a "Payment deadline" date input `new-go-payment-deadline`
  next to the existing Deadline field; read its value into `paymentDeadline`, store it
  on `allGOs[id]`, and send `payment_deadline: paymentDeadline` in the
  `apiPost('createGO', ...)` payload.
- **Edit GO**: add `edit-go-payment-deadline` date input next to the Deadline field;
  populate it on open with `fmtDate(go.paymentDeadline)`; in `saveGOEdits`, read
  `go.paymentDeadline = document.getElementById('edit-go-payment-deadline').value`
  and add `payment_deadline: go.paymentDeadline` to the `apiPost('updateGO', ...)`.
- **Sync reconstruction** (`syncFromBackend`): on the `rebuilt` GO object, set
  `paymentDeadline: fmtDate(go.payment_deadline)` (alongside `deadline`).
- **Buyer My orders** (`renderMyOrderGoBlock`): when `s.owed > 0` **and**
  `allGOs[g.go_id]?.paymentDeadline`, show a line **"Pay by \<fmtDate\>"** in the
  payment section (near the Owed summary / pay form). Hidden when owed is 0 or no
  deadline is set.

## Naming / consistency

Frontend field is `paymentDeadline`; backend column/payload is `payment_deadline`.
The `apiPost` payloads translate explicitly (`payment_deadline: <camel>`), mirroring
how the existing `deadline` field is a shared name.

## Out of scope (YAGNI)

- Any enforcement/auto-drop on the deadline (that's the separate "reassign
  unpaid-past-deadline" feature — see the NOTES file).
- Time-of-day (date only, like the preorder deadline).
- Showing the deadline on the admin GO list or the total card.

## Redeploy note

`payment_deadline` requires redeploying `go-manager-backend.gs`. Before redeploy the
frontend degrades gracefully: `go.payment_deadline` is undefined → `paymentDeadline`
is '' → no "Pay by" line shows; setting a deadline in Edit/Create GO won't persist
until the redeploy.
