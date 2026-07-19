# Per-GO Joiner List + "Added to GC" Tracker — Design

**Date:** 2026-07-17
**Status:** Design approved, pending spec review

## Problem

The admin wants, per GO, the list of unique joiner Instagram handles so they can
add everyone to an IG group chat. Because the chat is often created before the GO
closes, new joiners arrive afterward — so the admin needs to **mark who's already
been added** and have that state persist (and follow them across devices).

## Goal

In the admin GO detail (Manage view), show a collapsible **Joiners** section
listing the GO's unique @handles, each with an "added to group chat" toggle whose
state is saved to the Google Sheet (synced across devices). IG can't create a chat
from a pasted list, so there is **no bulk copy** — the value is the checklist, with
not-yet-added joiners surfaced first and per-handle tap-to-copy for pasting into
IG's member search.

## Backend (Apps Script — REQUIRES REDEPLOY)

New sheet **`gc_added`** with columns `go_id, username` (one row = that user is
marked added to the GC for that GO).

- `SHEET_GC_ADDED = 'gc_added'`; add `ensureSheet(ss, SHEET_GC_ADDED, ['go_id','username'])`
  in `bootstrapSheets`.
- **`getGcAdded()`** (doGet) → `{ gc_added: [ {go_id, username}, ... ] }` (via
  `sheetToObjects`, or `[]` if the sheet doesn't exist yet).
- **`setGcAdded(data)`** (doPost) with `{ go_id, username, added }`:
  - Scan `gc_added` for a row matching `go_id` **and** username (case-insensitive,
    trimmed).
  - `added === true` → append `[go_id, username]` if no match exists (idempotent).
  - `added` falsy → delete the matching row if present.
  - Returns `{ ok: true }`.
- Route both in `doGet`/`doPost` alongside the existing actions.

Deleting `deleteGO` should also clear that GO's `gc_added` rows (mirrors how it
clears joiners). Nice-to-have; include if trivial, otherwise out of scope.

## Frontend

### Joiner collection

`goJoiners(go)` → array of unique usernames across **all** the GO's claims:
- set-based sub-items (`si.sets` → each filled `set.slots[member].user`),
- claims-based sub-items (`si.claims` → each `c.user`).

Dedup case-insensitively (trim + lowercase key), keeping the first-seen display
casing. Dropped claims still count (the buyer may already be in the chat). Returns
the handles; render decides ordering.

### Added-state, loaded on sync

- Module state `gcAdded = {}` — `go_id → { normalizedUsername: true }`.
- In `syncFromBackend`, add `apiGet('getGcAdded')` to the existing `Promise.all`,
  then build `gcAdded` from its rows: `gcAdded[go_id][norm(username)] = true`.
- `isGcAdded(goId, username)` → `!!(gcAdded[goId] && gcAdded[goId][norm(username)])`.

### Joiners section in `renderDetailContent`

At the **top** of the GO detail (a GO-level section, above the sub-items), a
collapsible block (default **collapsed**, reusing the app's chevron pattern with a
per-GO open flag, e.g. `gcOpen[go.id]`):

- Header (click to toggle): `▸ Joiners — X added / N total` where N =
  `goJoiners(go).length`, X = how many are in `gcAdded[go.id]`.
- Body (when open): the handles, **not-yet-added first, then alphabetical**. Each
  row:
  - the **@handle** as a tappable element (`onclick` copies `@username` via
    `navigator.clipboard.writeText`, with a toast "Copied @username"),
  - a toggle button: **"✓ In GC"** (teal/`badge-secured` style) when added, else
    **"Add to GC"** (muted). Clicking calls `toggleGcAdded(go.id, username)`.

### Toggle + copy handlers

- `toggleGcAdded(goId, username)`: flip local `gcAdded[goId][norm(username)]`
  (add/delete key), then `persistWrite(apiPost('setGcAdded', { go_id: goId,
  username, added }), 'Group-chat mark')` (reliable write — surfaces failure +
  resync). Re-render the detail so the section and counts update.
- `copyHandle(username)`: `navigator.clipboard.writeText('@' + username)` +
  toast. Guard for environments without `navigator.clipboard` (toast a fallback).

## Data / reuse

- Uses existing `sameUser`/normalization convention, `persistWrite`, the chevron
  collapse pattern (`adminOpenSI`-style), `renderDetailContent` re-render.
- No change to claims, payments, or other features.

## Out of scope (YAGNI)

- Bulk copy / export of handles (IG can't use it).
- Auto-detecting who's actually in the IG chat (manual toggle only).
- GC tracking for the Shop or anything not tied to a GO.
- Showing the joiner list on the buyer side.

## Redeploy note

The `gc_added` sheet + `getGcAdded`/`setGcAdded` endpoints require redeploying
`go-manager-backend.gs`. The frontend degrades gracefully before redeploy:
`getGcAdded` returns `{ error: ... }` → `gcAdded` stays empty (everyone shows
"Add to GC"); toggling will fail the `setGcAdded` write and `persistWrite` will
toast + resync, so nothing persists until the redeploy — expected.
