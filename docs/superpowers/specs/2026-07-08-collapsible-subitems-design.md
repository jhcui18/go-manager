# Collapsible sub-item sections — Design

## Problem
GOs with many sub-items (e.g. This&That: ~13 photocard POBs, each with several sets)
render every sub-item's content inline, so the admin Manage page and the buyer claim page
become one very long scroll. Finding a specific sub-item (e.g. "Soundwave") means scrolling
past everything above it.

## Design — collapse each sub-item into a one-line header (admin + buyer)
Each sub-item becomes a collapsible section:
- **Header (click to toggle):** `▸`/`▾` chevron + name + existing badges + a **summary**:
  - set-based (photocard / album member): `N sets · M secured`
  - FCFS (versioned / single / random / merch): `N claimed`
- **Body:** the existing rendered content, shown/hidden via `display`.
- **Default: collapsed** (all sub-items closed on open).
- **State persists across re-renders** — securing a set, logging a claim, or a sync must not
  re-collapse a section the admin has open. Kept in per-view state objects keyed by sub-item id.
- **Admin Manage:** an **Expand all / Collapse all** control at the top of the detail view.
- **Buyer claim page:** same collapsible headers, default collapsed; buyers scan version names
  and expand the one they want.

## Implementation
- `setsSummary(si)` helper → the summary string (counts real sets = sets with any filled slot;
  secured = sets with `status==='secured'`; FCFS = summed claim qty).
- Admin (`renderDetailContent`): wrap each `.admin-section` with a clickable header
  (`toggleAdminSI(siId)`) and a body div (`adm-body-<id>`) whose `display` follows
  `adminOpenSI[siId]` (default false). `expandAllAdmin(open)` sets every sub-item's state and
  re-applies. State object `adminOpenSI` is module-level so `renderDetailContent` re-renders
  respect it.
- Buyer (`renderClaimPage`): wrap each sub-item's rendered HTML in a header
  (`toggleClaimSI(goId, siId)`) + body div; state `claimOpenSI` keyed by `goId+'|'+siId`,
  default false. Claim-state init and pickers are unchanged (bodies only hidden, ids preserved).
- Toggling flips the state and the body's `display` + chevron directly (no full re-render).

## Scope / non-goals
- Frontend-only; no backend/schema change.
- No change to how claims/sets/pickers work — only visibility/wrapping.

## Verification (manual, in browser)
- Open This&That GO in admin Manage: all sub-items collapsed as one-liners with correct
  `N sets · M secured`; click Soundwave → expands; secure a set → stays expanded; Collapse all
  closes everything.
- Buyer claim page for the same GO: collapsed version list; expand one and claim normally.
