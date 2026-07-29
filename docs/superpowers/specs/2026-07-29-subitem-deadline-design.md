# Per-POB (Sub-Item) Deadline — Display Only — Design

**Date:** 2026-07-29
**Status:** Design approved, pending spec review

## Problem

A GO has one deadline, but its POBs (sub-items) close at different times. The admin
wants to show a **per-POB deadline date** to buyers ("Closes <date>"). This is the
display-only companion to the Close POB feature (which stops claims); the deadline
does **not** auto-close — the admin still closes each POB by hand.

## Goal

Let the admin set an optional **deadline date per sub-item**, shown to buyers on that
POB. Purely informational; no effect on claim placement or the closed state.

## Decisions

- **Display only** — no auto-close, no interaction with `isPobClosed`/placement.
- **Date granularity** (YYYY-MM-DD), like the GO deadline (`fmtDate` formats it).
- **Set inline** in the admin GO detail, a small date field per POB next to the
  Close POB button; saves immediately on change; clearing it removes the deadline.
- **Buyers see "Closes <date>"** on the POB card **only while the POB is open** — once
  closed, the Closed banner shows instead (no contradictory "Closes" text on a
  closed POB).
- **Persisted** in a keyed store, mirroring `closed_subitems`.

## Data model (backend — REQUIRES REDEPLOY)

New **`subitem_deadlines`** store:

- Sheet `subitem_deadlines`, columns `go_id, sub_item_id, deadline`.
- `getSubItemDeadlines()` (doGet) → `{ subitem_deadlines: [{go_id, sub_item_id, deadline}] }`.
- `setSubItemDeadline(data)` (doPost) `{ go_id, sub_item_id, deadline }` — **upsert**
  (unlike the closed flag, deadline is a value that changes):
  - match a row on `go_id` + `sub_item_id`;
  - if `deadline` non-empty: update that row's `deadline` if present, else append a
    new row;
  - if `deadline` empty/falsy: delete the row if present.
- Route both. `deleteGO` clears the GO's `subitem_deadlines` rows.

## Frontend

### State + reconstruction

- Module `subItemDeadlines = {}` — key `go_id + '|' + sub_item_id` → deadline string.
  Loaded in `syncFromBackend` from `getSubItemDeadlines` (added to the `Promise.all`),
  parsed **before** reconstruction (same spot as `closedSubItems`).
- Stamp `si.deadline = subItemDeadlines[go.go_id + '|' + s.id] || ''` on each rebuilt
  sub-item (right beside the existing `s.closed` stamp).
- Helper `subItemDeadline(goId, siId)` → the stored string (or '').

### Admin — inline date field

- In the admin GO-detail sub-item header (`renderDetailContent`, beside the Close POB
  button), add a small **date input**: `type="date"`, value `si.deadline || ''`,
  `onclick="event.stopPropagation()"` (so it doesn't fire the header's collapse
  toggle), `onchange="setSubItemDeadline('<goId>','<siId>', this.value)"`, with a tiny
  "closes" label.
- `setSubItemDeadline(goId, siId, value)`: set `si.deadline = value`; update
  `subItemDeadlines[goId+'|'+siId]` (delete the key when value is empty); persist
  `persistWrite(apiPost('setSubItemDeadline', { go_id, sub_item_id, deadline:value }), 'Deadline')`;
  `renderDetailContent()`; toast.

### Buyer — "Closes <date>"

- On each POB public card (`renderSetSubItemPublic`, `renderBatchSubItemPublic`,
  `renderVersionedSubItemPublic`, `renderSingleSubItemPublic`): when `si.deadline` is
  set **and the POB is not closed** (`!isPobClosed(allGOs[goId], si)`), show a small
  line **"Closes <fmtDate(si.deadline)>"** near the POB name.

## Out of scope (YAGNI)

- Auto-close at the deadline (explicitly display-only).
- Per-set-number deadlines.
- Payment deadline per POB (GO-level `paymentDeadline` unchanged).
- Timezone handling beyond what the GO deadline already does (sheet TZ, like existing
  `deadline`).

## Testing

- **Backend:** `getSubItemDeadlines` returns `[]` initially; `setSubItemDeadline`
  upsert (add → update the same row, not a duplicate) and clear (delete) round-trip;
  `deleteGO` clears rows. `node --check` the backend copy.
- **Frontend:** JS-parse `index.html`. Node logic check of the upsert-key behavior is
  unnecessary (no non-trivial pure function); a small check that the map parse +
  `si.deadline` stamp read the right key is sufficient by inspection.
- **Manual:** set a deadline on a POB → buyers see "Closes <date>"; change it → updates
  (no duplicate row); clear it → text disappears; close the POB → "Closes" hidden,
  Closed banner shows; refresh persists.

## Redeploy note

`subitem_deadlines` sheet + `getSubItemDeadlines`/`setSubItemDeadline` require
redeploying `go-manager-backend.gs` + one bootstrap. Pre-redeploy: `getSubItemDeadlines`
errors → map empty → no deadlines shown (safe degrade); `setSubItemDeadline` writes
fail (`persistWrite` surfaces + resyncs).
