# Per-Set Payment Due Date — Design

**Date:** 2026-07-29
**Status:** Design approved, pending spec review

## Problem

Sets within a POB get secured/ordered at different times, so payment for a secured
set comes due at different times. There's only a GO-level payment deadline today. The
admin wants a **payment due date per set**, shown to the joiners with claims in that set.

## Goal

Let the admin set an optional **due date per set** (inline on the admin set card).
Each joiner sees **"Pay by <date>"** on their **secured** claims for that set in My
Orders. Display only — no auto-drop.

## Decisions (all as proposed)

- **Per set**, set on the admin set card next to the Secure control; saves immediately.
- **Joiner sees "Pay by <date>"** on their **secured, unpaid** claims for that set in
  My Orders (payment is only owed on secured claims). Falls back to the GO-level
  payment deadline block note (unchanged) when a set has no per-set date.
- **Display only** (no effect on placement/closed/owed).
- Date granularity YYYY-MM-DD (`fmtDate`), like the GO deadline.
- Keyed by **set number** (`go_id, sub_item_id, set_num`) — the due date belongs to
  "set N of this POB"; it stays with the number even if claims shift between sets.

## Data model (backend — REQUIRES REDEPLOY)

New **`set_payment_due`** store (mirrors `secured_sets`, which is also keyed by
`sub_item_id`+`set_num`, but this is an upsert carrying a value):

- Sheet `set_payment_due`, columns `go_id, sub_item_id, set_num, due_date`.
- `getSetPaymentDue()` (doGet) → `{ set_payment_due: [{go_id, sub_item_id, set_num, due_date}] }`.
- `setSetPaymentDue(data)` (doPost) `{ go_id, sub_item_id, set_num, due_date }` — upsert:
  match a row on `sub_item_id` + String(`set_num`); non-empty `due_date` → update that
  row's due_date if present else append; empty → delete the row if present.
- Route both. `deleteGO` clears the GO's `set_payment_due` rows.

## Frontend

### State + load

- Module `setPaymentDue = {}` — key `sub_item_id + '|' + set_num` → due_date string.
  Loaded in `syncFromBackend` from `getSetPaymentDue` (added to the `Promise.all`),
  parsed **before** reconstruction (same spot as `closedSubItems`/`subItemDeadlines`),
  storing `fmtDate(r.due_date)`.
- Helper `setDueDate(siId, setNum)` → the stored string (or '').

(No per-set stamp needed — render sites read `setDueDate(si.id, set.num)` directly,
so the value survives claim moves that change which claims are in a set number.)

### Admin — inline date field on the set card

- In `renderDetailContent` set-based branch, the set card header has the Set label +
  Secure/Unsecure control. Add a small **date input** in that header row:
  `type="date"`, value `setDueDate(si.id, set.num)`, `onclick="event.stopPropagation()"`,
  `onchange="setSetPaymentDue('<goId>','<siId>',<set.num>, this.value)"`, with a tiny
  "pay by" label. Shown for every set (secured or not).
- `setSetPaymentDue(goId, siId, setNum, value)`: update `setPaymentDue[siId+'|'+setNum]`
  (delete the key when value empty); persist `persistWrite(apiPost('setSetPaymentDue',
  { go_id, sub_item_id, set_num, due_date:value }), 'Payment due')`; re-render; toast.

### Joiner — "Pay by <date>" in My Orders

- `doLookup`: the set-based rows (OT row + per-member row) already have `si` and `set`
  in scope — add `due: setDueDate(si.id, set.num)` to each. Claims-based rows get
  `due: ''` (no per-set due).
- `renderMyOrderGoBlock` claim rows: in the Payment cell, when a row is **Secured**,
  **not paid**, and `r.due` is set, render a small red **"Pay by <r.due>"** under the
  Unpaid badge.
- The existing GO-level `deadlineNote` block stays as-is (general fallback).

## Out of scope (YAGNI)

- Auto-drop / late handling at the due date (display only).
- Per-set due on non-set (FCFS/merch) claims — those use the GO-level payment deadline.
- Showing the due date to buyers on the public group-order board (My Orders only).

## Testing

- **Backend:** `getSetPaymentDue` returns `[]` initially; `setSetPaymentDue` upsert
  (add → update same row, no dup) and clear (delete) round-trip; `deleteGO` clears
  rows. `node --check` the backend copy.
- **Frontend:** JS-parse `index.html`. Inspect that the map key (`siId|setNum`) and the
  admin/joiner read sites agree.
- **Manual:** set a due date on a set → a joiner with a secured claim in that set sees
  "Pay by <date>" in My Orders; an unsecured/paid claim shows nothing; change/clear the
  date → updates (no duplicate row); refresh persists; a different set's date is
  independent.

## Redeploy note

`set_payment_due` sheet + `getSetPaymentDue`/`setSetPaymentDue` require redeploying
`go-manager-backend.gs` + one bootstrap. Pre-redeploy: `getSetPaymentDue` errors → map
empty → no "Pay by" shown (safe degrade); `setSetPaymentDue` writes fail (`persistWrite`
surfaces + resyncs).
