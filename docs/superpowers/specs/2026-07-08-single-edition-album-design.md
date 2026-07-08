# Single-edition (version-less) album sub-item — design

**Date:** 2026-07-08
**File touched:** `index.html` only (backend `.gs` unchanged — it serializes sub-items generically)

## Problem

When creating an album GO, each sub-item must currently be one of two kinds:

- **Member ver** — pick a member (set-based)
- **Version pick** — buyer selects A/B/… (`kind:'versioned'`)

Some albums have **no sub-versions** — a single edition with nothing to choose. There is no
option for this today. Two concrete blockers:

- The album Kind dropdown offers only `member` and `versioned` (`index.html:1828`, `2152`).
- `createGO` hardcodes `|| 'A,B'` (`index.html:1918`), so even an empty versions field is
  forced to A/B.

## Solution

Add an explicit new album sub-item kind: **`single`** ("Single edition (no versions)").
The buyer just picks a quantity — no version or member selection, FCFS.

Approach chosen (over overloading `versioned` with an empty `versions` array) because an
explicit named kind reads clearly and keeps `random`/`Default` labels from leaking into the
buyer/admin UI.

### Data shape

```javascript
{ id, name, kind:'single', price, claims:[] }
```

- No `members`, no `versions`.
- Claim shape (same as merch random, but nothing assigned):
  `{ user, qty, assignedVers:[], payment, fulfillment, claim_id }`
- Written to Sheets exactly like other FCFS claims: `member_or_version:''`, `assigned_vers:''`.

## Buyer experience

- Item name, price, quantity picker (−/+), and "N claimed".
- **No version badge, no member tiles, no "Default" label.**
- Reuses the existing "random ver — just qty" card markup and the `adjustVersionedQty` handler.

## Touch points (all in `index.html`)

### Create GO
1. **Kind dropdown** (`~1828`): add `<option value="single">Single edition (no versions)</option>`.
2. **`onSubItemKindChange`** (`~1869`): `single` → clear the `si-extra-${id}` area (no
   members/versions input).
3. **`createGO`** album branch (`~1907`): `single` → `subItems.push({ id, name, kind:'single', price, claims:[] })`.

### Buyer / claim
4. **Public render routing** (`~785`): album loop routes `kind==='single'` to a new
   `renderSingleSubItemPublic(si, goId)` — quantity-only card, no version tiles, no badge.
5. **claim-state init** (`~800`) and **`submitClaim`** (`~1229`): `single` already falls through
   correctly — `type:'versioned', qty:0`, and `si.versions` is undefined so `assignedVers:[]`
   (nothing leaks). No code change; covered by a test to lock the behavior in.

### Admin
6. **Claims table `hasMemberCol`** (`1646`): exclude `single` so no empty "Member/Ver" column
   renders. New condition: `si.kind==='member' || (si.kind!=='versioned' && si.kind!=='random' && si.kind!=='single')`.
7. **Detail badge** (`~1568`): add a small "single edition" badge (admin-side clarity only).

### Persistence — MUST fix
8. **`syncFromBackend` reconstruction** (`~3004`): add an `rebuilt.type==='album' && kind==='single'`
   branch that rebuilds `{ id, name, kind:'single', price, claims: buildVersionedClaims(go.claims, si.sub_item_id) }`.
   Without this branch the sub-item is **silently dropped on refresh** (data loss on reload).

### Edit GO (for consistency)
9. **Edit dropdown** (`2152`): add the `single` option.
10. **`onEditSubItemKindChange`** (`~2189`): `single` → clear extra area.
11. **Existing sub-item render in edit** (`~2254`): handle `kind==='single'` (name + price only,
    no members/versions inputs) so editing a single-edition GO round-trips without corruption.
12. **Edit save** (`~2291`): `single` → push `{ id, name, kind:'single', price, claims:[] }`.

## Out of scope

- Backend `.gs` changes — none needed; sub-items are serialized generically (`go-manager-backend.gs:136-167`).
- Email notifications.
- Shop / leftover-listing rendering of single-edition items (existing FCFS handling suffices;
  revisit only if a gap surfaces).

## Testing

Since this is a single-file browser app with no test harness, verification is manual plus a
small assertion script for the pure logic:

- **Create:** make an album GO with one `single` sub-item; confirm the saved object has
  `kind:'single'`, no `versions`, `claims:[]`.
- **Claim:** as a buyer, pick qty 2; confirm one claim with `qty:2`, `assignedVers:[]`,
  and Sheets row `member_or_version:''`, `assigned_vers:''`.
- **Admin:** detail table shows qty with no "Member/Ver" or "Versions" column; count reflects claims.
- **Refresh/sync:** reload with `API_URL` set; confirm the single-edition sub-item and its
  claims are reconstructed (not dropped).
- **Edit:** open Edit GO on the single-edition GO; confirm the kind shows `single` and saving
  preserves it.
