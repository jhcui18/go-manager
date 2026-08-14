#!/usr/bin/env node
// Parity: legacy pipeline (snapshot.json -> extracted builders) vs new pipeline
// (Supabase REST -> claimRowToLegacy -> same builders). Boards must match.
// Usage: SUPABASE_URL=... SUPABASE_ANON_KEY=... node tests/parity.mjs
import fs from 'node:fs';
import vm from 'node:vm';

const src = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');

// Extract a top-level `function name(...) {...}` by balanced-brace scan.
function extractFunction(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`function ${name} not found`);
  let i = src.indexOf('{', start), depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  throw new Error(`unbalanced braces in ${name}`);
}

const sandbox = { securedSets: {}, console };
vm.createContext(sandbox);
// NOTE: deriveSetStatus calls isSetFlagged(siId, set.num), a separate top-level
// function that reads the `securedSets` global — it is not inlined into
// deriveSetStatus. The brief's extraction list omitted it; without it
// deriveSetStatus throws ReferenceError: isSetFlagged is not defined. Added here.
for (const fn of ['isSetFlagged', 'buildSetsFromClaims', 'buildVersionedClaims', 'buildBatchClaims',
                  'deriveSetStatus', 'nextSetNum', 'parseMembers', 'tryParse',
                  'claimRowToLegacy', 'isBatch'])
  vm.runInContext(extractFunction(fn), sandbox);

const BASE = process.env.SUPABASE_URL + '/rest/v1';
const HDRS = { apikey: process.env.SUPABASE_ANON_KEY,
               Authorization: 'Bearer ' + process.env.SUPABASE_ANON_KEY };
async function rest(path) {
  const r = await fetch(BASE + path, { headers: HDRS });
  if (!r.ok) throw new Error(path + ' -> ' + r.status);
  return r.json();
}
// PostgREST caps a single response at 1000 rows (default max-rows). Page through
// with the Range header until a short page comes back.
async function restAll(path, pageSize = 1000) {
  let offset = 0, out = [];
  for (;;) {
    const r = await fetch(BASE + path, {
      headers: { ...HDRS, Range: `${offset}-${offset + pageSize - 1}` }
    });
    if (!r.ok && r.status !== 206) throw new Error(path + ' -> ' + r.status);
    const page = await r.json();
    out = out.concat(page);
    if (page.length < pageSize) break;
    offset += pageSize;
  }
  return out;
}

// Canonical board form: slots keyed by member with only cross-system-stable fields.
function canonSets(sets) {
  return sets.map(s => ({
    num: s.num, status: s.status,
    slots: Object.fromEntries(Object.entries(s.slots).map(([m, v]) =>
      [m, v && { user: String(v.user).replace(/^@/, '').toLowerCase(),
                 ot: !!v.ot, claim_status: v.claim_status || 'pending',
                 payment: v.payment || 'unpaid' }]))
  }));
}
function canonClaims(claims) {
  return claims
    .map(c => ({ user: String(c.user).replace(/^@/, '').toLowerCase(),
                 // qty: cosmetic type normalization. The xlsx snapshot stringifies every
                 // cell (export_snapshot.py casts with str(v)), so a numeric xlsx cell like
                 // 2 round-trips as the JS string "2.0" through buildVersionedClaims (which
                 // does `qty: c.qty || 1`, no parseInt). The DB side returns a real Postgres
                 // integer. Number(...) normalizes both sides to the same numeric type without
                 // touching user/member/claim_status/payment.
                 member: c.member || '', qty: Number(c.qty) || 1,
                 claim_status: c.claim_status || 'pending', payment: c.payment || 'unpaid' }))
    .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
}

const snap = JSON.parse(fs.readFileSync(new URL('./fixtures/snapshot.json', import.meta.url)));
const SET_KINDS = new Set(['photocard', 'member', 'member-set']);

// New-side data, fetched once. gos/sub_items: 18 top-level rows, no paging needed.
// claims (4524 rows) and secured sets certainly exceed the 1000-row PostgREST cap.
const dbGos = await rest('/gos?select=id,legacy_id,min_secure,sub_items(id,legacy_id,kind,order_mode,batch_size,min_secure,members(name,position))');
const dbSecured = await restAll('/sets?select=set_no,sub_items!inner(legacy_id,go_id)&status=eq.secured');
const dbClaims = await restAll('/claims?select=id,legacy_id,sub_item_id,username,email,qty,is_ot,assigned_version,status,payment_status,fulfillment,created_at,updated_at,members(name),versions(name),sets(set_no),sub_items!inner(go_id,legacy_id)');

console.log(`fetched: gos=${dbGos.length} secured_sets=${dbSecured.length} claims=${dbClaims.length}`);
if (dbClaims.length !== 4524) {
  console.error(`EXPECTED 4524 claims fetched, got ${dbClaims.length} — pagination may be incomplete`);
}

let failures = 0;
for (const g of snap.gos) {
  const dbGo = dbGos.find(x => x.legacy_id === g.go_id);
  if (!dbGo) { console.error(`MISSING GO in db: ${g.go_id}`); failures++; continue; }
  const legacyClaims = snap.claims.filter(c => c.go_id === g.go_id);
  const newClaimsRaw = dbClaims.filter(c => c.sub_items.go_id === dbGo.id);
  const newClaims = newClaimsRaw.map(c => sandbox.claimRowToLegacy({
    ...c, sub_items: { go_id: c.sub_items.go_id } }));

  for (const si of g.subItems) {
    if (!si.sub_item_id) continue;
    const dbSi = dbGo.sub_items.find(x => x.legacy_id === si.sub_item_id);
    if (!dbSi) { console.error(`MISSING sub_item ${g.go_id}/${si.sub_item_id}`); failures++; continue; }
    const kind = si.kind || g.type || 'photocard';
    const ms = parseInt(si.min_secure) || 7;
    const members = sandbox.parseMembers(si.members);
    const oldOfSi = legacyClaims.filter(c => c.sub_item_id === si.sub_item_id);
    const newOfSi = newClaims.filter(c => c.sub_item_id === dbSi.id);

    // securedSets keyed per pipeline's own sub_item ids.
    sandbox.securedSets = {};
    for (const r of snap.secured_sets)
      if (r.sub_item_id === si.sub_item_id) sandbox.securedSets[si.sub_item_id + '|' + parseInt(r.set_num)] = true;
    const oldBoard = SET_KINDS.has(kind) && ms >= 0
      ? canonSets(sandbox.buildSetsFromClaims(oldOfSi, si.sub_item_id, members))
      : canonClaims(ms < 0 ? sandbox.buildBatchClaims(oldOfSi, si.sub_item_id)
                           : sandbox.buildVersionedClaims(oldOfSi, si.sub_item_id));
    sandbox.securedSets = {};
    for (const r of dbSecured)
      if (r.sub_items.legacy_id === si.sub_item_id) sandbox.securedSets[dbSi.id + '|' + r.set_no] = true;
    const dbMembers = (dbSi.members || []).sort((a, b) => a.position - b.position).map(m => m.name);
    const newBoard = SET_KINDS.has(kind) && ms >= 0
      ? canonSets(sandbox.buildSetsFromClaims(newOfSi, dbSi.id, dbMembers))
      : canonClaims(ms < 0 ? sandbox.buildBatchClaims(newOfSi, dbSi.id)
                           : sandbox.buildVersionedClaims(newOfSi, dbSi.id));

    const a = JSON.stringify(oldBoard), b = JSON.stringify(newBoard);
    if (a !== b) {
      failures++;
      console.error(`MISMATCH ${g.name} / ${si.name} (${si.sub_item_id})`);
      console.error('  old:', a.slice(0, 400));
      console.error('  new:', b.slice(0, 400));
    }
  }
}
console.log(failures === 0 ? `PARITY OK — all ${snap.gos.length} GOs match`
                           : `${failures} mismatches`);
process.exit(failures === 0 ? 0 : 1);
