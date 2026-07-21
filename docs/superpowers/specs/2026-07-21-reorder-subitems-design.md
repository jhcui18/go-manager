# Reorder Sub-items in a GO (drag) — Design

**Date:** 2026-07-21
**Status:** Design approved, pending spec review

## Problem

Sub-items (POBs / listing items) display in the order they were added, with no way
to reorder them. The admin wants to reorder them (e.g. a merch GO's items).

## Goal

Drag-to-reorder the sub-items in the **Edit GO** list. The new order applies when
the admin clicks **Save changes** (consistent with the rest of the Edit-GO form).
Frontend-only — `updateGO` already rewrites the sub-items sheet in `subItems` array
order, so persisting the reordered array is all that's needed.

## Mechanism (pointer events — mouse + touch)

Each sub-item row in `renderEditSubItems` gets a **drag handle** (⠿). Dragging uses
**pointer events** (unified mouse/touch), not HTML5 drag (which doesn't work on
touch). The handle carries `touch-action:none` so a drag doesn't scroll the page.

- **pointerdown** on a handle → start dragging that row's wrapper
  (`#edit-wrap-<si.id>`); dim it; attach document-level `pointermove`/`pointerup`.
- **pointermove** → **live-reorder the DOM**: find the row whose vertical midpoint
  the pointer has crossed and `insertBefore`/`appendChild` the dragged wrapper there.
  Because we move the actual DOM nodes (not re-render), any in-progress typed edits
  in those rows are preserved automatically.
- **pointerup** → stop; un-dim; **reorder `currentGO.subItems` to match the new DOM
  order** (read each child's `edit-wrap-<id>` → id, sort the array by that order).
  Do **not** re-render (keeps the live-edited DOM intact).

## Persistence

The reordered `currentGO.subItems` array is saved on **Save changes**: `saveGOEdits`
reads each sub-item by id and sends `subItems` in array order to `updateGO`, which
rewrites the `go_<id>` sheet in that order. No backend change, no redeploy.

## Scope / reuse

- Works for all GO types (photocard / album / merch) — the handle is added to every
  sub-item row regardless of type.
- New drag state + 3 handlers (`onSubItemDragStart/Move/End`) + a handle element in
  `renderEditSubItems`. No change to `saveGOEdits` or the backend.
- Edits preserved because dragging moves DOM nodes rather than re-rendering.

## Out of scope (YAGNI)

- Reordering from the Manage (detail) view — Edit GO only.
- Reordering members within a sub-item, or sets.
- Auto-save on drop (design chose apply-on-Save).

## Backend impact

None.
