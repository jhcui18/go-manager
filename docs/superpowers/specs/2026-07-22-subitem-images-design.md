# Picture per Sub-item — Design

**Date:** 2026-07-22
**Status:** Design approved, pending spec review

## Problem

GO sub-items (POB sets like Makestar/Soundwave, and merch items) have no image.
The admin wants one picture per sub-item so buyers see what they're claiming.

## Goal

One optional `imageUrl` per sub-item (uniform across photocard / album / merch —
a POB set is a sub-item, same as a merch item). Admin sets it via a direct image
URL in Create GO and Edit GO; it shows on the buyer claim page and as a thumbnail in
the admin GO detail. Reuses the existing shop-listing image pattern (direct URL,
`onerror` hides broken links). No file upload (the app has no file backend).

## Data model

Sub-item gains an `imageUrl` string (frontend, camelCase — like `otPrice`).
Backend sub-item sheet gains an **`image_url`** column (last column). `ensureSheet`
auto-appends it to existing `go_<id>` sheets on bootstrap, so existing GOs migrate.
The backend reads the frontend field name (`si.imageUrl`) when writing rows — the
same way it already reads `si.otPrice` / `si.minSecure` — and `getAllGOs` returns
the `image_url` column, which sync maps back to `imageUrl`.

**Backend change → requires a redeploy** of `go-manager-backend.gs`.

## Backend (Apps Script)

- `createGO`: add `'image_url'` to the `ensureSheet('go_'+goId, [...])` header, and
  append `si.imageUrl || ''` as the final value in the sub-item `appendRow`.
- `updateGO`: add `'image_url'` to `HEADERS`, and push `si.imageUrl || ''` as the
  final value in the `grid` row.
- `getAllGOs`: no change (`sheetToObjects` returns the new column).

## Frontend

### Admin input (one image field per sub-item form)

A single **Image URL** text field is added once per sub-item form (not per type),
placed after the type-specific fields:
- **Create GO** (`addSubItem`): field id `si-img-${id}`.
- **Edit GO existing item** (`renderEditSubItems`): field id `edit-si-img-${si.id}`,
  pre-filled with `si.imageUrl`.
- **Edit GO new item** (`addEditSubItem`): field id `edit-si-img-${id}`.

A tiny helper builds the field markup so the three call sites stay consistent:
`imgFieldHtml(fieldId, current)` → the `<div class="field">…<input></div>`.

### Saving (single post-pass, no per-branch edits)

- **`createGO`**: after the `subItems` array is assembled, one pass sets
  `si.imageUrl = value of #si-img-<si.id>` for each. The create payload already
  spreads the sub-item objects, and the backend reads `si.imageUrl`.
- **`saveGOEdits`**: after the existing-item loop, the new-item collection, and the
  dedupe/name-filter, one pass sets `si.imageUrl = value of #edit-si-img-<si.id>`
  for each sub-item (covers existing and new). Then the existing `updateGO` post
  carries them.

### Sync reconstruction (map, not per-branch edits)

In `syncFromBackend`, while iterating the raw sheet sub-items, record
`imgById[si.sub_item_id] = si.image_url || ''`; after `rebuilt.subItems` is built,
one pass sets `s.imageUrl = imgById[s.id] || ''` on each. This avoids editing all
six reconstruction branches.

### Display

A render helper `siImg(si, size)` returns an `<img>` (or `''` when no image):
`si.imageUrl ? '<img src="…" onerror="this.style.display=\'none\'" style="…">' : ''`,
with `size` controlling `'card'` (full-width, top of card) vs `'thumb'` (small,
inline in admin header).

- **Buyer claim page**: insert `${siImg(si,'card')}` at the top of each sub-item
  card — in `renderSetSubItemPublic`, `renderVersionedSubItemPublic`,
  `renderSingleSubItemPublic`, `renderBatchSubItemPublic`, and the merch item render
  (`renderMerchPublic`).
- **Admin GO detail** (`renderDetailContent`): insert `${siImg(si,'thumb')}` next to
  each sub-item header.

## Scope / reuse

- Direct URL only (mirrors shop listings; broken links auto-hide via `onerror`).
- One image per sub-item (no galleries).
- Not shown in buyer My orders (admin chose claim page + admin detail only).
- Frontend field `imageUrl` ↔ backend column/payload `image_url` (mirrors
  price/otPrice mapping).

## Out of scope (YAGNI)

- File upload / hosting.
- Multiple images per sub-item.
- Per-member or per-version images.

## Redeploy note

The `image_url` column + create/update wiring require redeploying
`go-manager-backend.gs`. Before redeploy the frontend degrades gracefully:
`si.image_url` is undefined → `imageUrl` empty → no image renders; setting an image
won't persist until the redeploy.
