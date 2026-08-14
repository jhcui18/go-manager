# Cutover runbook (target: ~1-hour claim freeze)

Preconditions: parity harness green, RLS script green, walkthrough complete,
keep-alive workflow merged-ready. Decide sandbox-becomes-prod (default: yes,
this project IS prod) — if a fresh project is preferred instead, re-apply
migrations 001-006 there first and swap URL+keys in index.html + keepalive.yml.
Note: the sandbox project (kkzmvuqfqbonsxebzaii) IS the production project by default; migrations 001-006 are already applied and tracked.

1. [ ] Announce the freeze (IG story/GC): "GO site paused ~1 hour for an upgrade."
2. [ ] Freeze: in the LIVE sheet's Apps Script, redeploy with `submitClaim`
       returning `{ok:false, error:'closed', message:'Site upgrade in progress'}`
       (single-line change), or simply mark every GO closed in the sheet UI.
       Note what was changed so it can be restored for rollback.
3. [ ] Fresh export: Google Sheets → File → Download → .xlsx →
       overwrite `GO Manager Data.xlsx` locally (do NOT commit — gitignored).
4. [ ] `python3 db/migrate_from_xlsx.py --dry-run` → quality report clean.
5. [ ] `SUPABASE_DB_URL=… python3 db/migrate_from_xlsx.py` → zero MISMATCH.
6. [ ] `python3 db/export_snapshot.py && node tests/parity.mjs` → PARITY OK.
7. [ ] Spot-check via SQL: newest claim in the sheet exists in `claims`;
       per-GO claim counts match the export.
8. [ ] Merge: `git checkout main && git merge supabase-migration && git push`.
9. [ ] Live smoke test (~15 min, phone): landing, open biggest GO, place + delete
       a test claim (admin), My Orders, admin login, payments tab.
10. [ ] Verify auth hardening: Supabase dashboard → Authentication → Sign In / Up → 'Allow new users to sign up' must be OFF (with our RLS model, any signed-up user would have full admin access). Also confirm exactly 1 user exists in Authentication → Users.
11. [ ] Reopen: announce claims are back.
12. [ ] Sheet afterlife: rename the spreadsheet "…(ARCHIVE — read only)";
        leave Apps Script dormant. Delete only weeks later, once confident.
13. [ ] Rotate the database password (Project Settings → Database → Reset database password) — the old one appeared in a Claude chat transcript during the build.

Rollback (any failure in 8-9): `git revert <merge-commit> && git push` —
GitHub Pages serves the Sheets version again within ~1 min; undo step 2's
freeze. The Sheet was frozen the whole window, so no data diverged.
