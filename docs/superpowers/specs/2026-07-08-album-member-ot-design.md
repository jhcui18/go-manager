# Album member-ver OT (full-set) option — Design

## Goal
Let an admin offer an **OT (full-set) option** on album sub-items of kind `member`,
exactly like photocards already have. A buyer can then claim a whole set of members
(e.g. **OT8** for Stray Kids' 8 members) at a single flat price.

## Context — most of this already exists and is shared
Album `member` sub-items are set-based and reuse the same machinery as photocards:
- `renderSetSubItemPublic` renders the **`OT{members.length} — full set`** tile whenever
  `si.otPrice > 0` (line ~885). Used for both photocard and album member.
- The set-based **submit** path writes OT full sets (`assigned_vers:'OT'`, `slot.ot`) (line ~1221).
- **My orders** prices an OT set as one flat-OT line (line ~1311).
- **Payment** treats an OT full set as one unit at the flat OT price (line ~2724).
- **Backend** `ot_price` column exists and is read back into `otPrice` for
  `photocard || (album && member)` on sync (line ~3051). No backend change needed.

The single gap: the **album sub-item create/edit forms never expose an OT price input**,
so album member sub-items can't get an `otPrice`, so the tile never appears.

## Design
1. **OT price input, member-kind only.** Add a "Full set (OT) price (USD)" number input
   to the album sub-item form. It lives in the member-kind extra area so it shows only
   when Kind = `member` (not `versioned`/`single` — OT is a full set of members).
   - Create form: `onSubItemKindChange` member branch + the initial member view in `addSubItem`.
   - Edit form: `onEditSubItemKindChange` member branch + the existing-item member render.
2. **Wire `otPrice` into the album member branches** of `createGO` and `saveGOEdits`
   (they currently omit it), reading the new input. Existing-item edit already reads
   `edit-si-otprice-${si.id}` generically (line ~2279), so no change there.
3. **Everything downstream is untouched** — set-based render/submit/lookup/payment already
   handle OT.

## Scope / non-goals
- OT only for album `member` kind. Versioned and single album kinds are unchanged.
- Label auto-sizes to the member count (`OT{n}`); no hardcoded "OT8".
- No backend/Apps Script change.

## Verification (manual, in browser)
- Create an album GO, add a member sub-item with members + an OT price. Buyer claim page
  shows the `OT{n} — full set` tile; claiming it fills a whole set at the flat OT price.
- Edit an existing album member sub-item, set/change the OT price, save, reopen — persists.
- My orders shows the OT claim as one flat-price line; admin can secure it.
