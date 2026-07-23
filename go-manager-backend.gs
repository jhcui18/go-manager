// ── GO Manager — Google Apps Script Backend ──────────────────────────────────
// Deploy as Web App: Execute as "Me", Access "Anyone"
// Paste your deployed Web App URL into the frontend app settings.

const SHEET_ID = SpreadsheetApp.getActiveSpreadsheet().getId();

// ── Sheet name constants ──────────────────────────────────────────────────────
const SHEET_GOS       = '_gos';        // master GO registry
const SHEET_JOINERS   = 'joiners';     // all claims across GOs
const SHEET_SHIPPING  = 'shipping';    // shipping requests
const SHEET_PAYMENTS  = 'payments';    // payment proof submissions
const SHEET_LISTINGS   = 'listings';     // shop listings (leftover stock)
const SHEET_SHOP_ORDERS = 'shop_orders'; // shop purchase orders
const SHEET_STORE_ORDERS = 'store_orders'; // admin's own orders placed with stores/proxies
const SHEET_GC_ADDED = 'gc_added'; // per-GO: joiners marked as added to the IG group chat

// ── Bootstrap: create all required sheets if missing ─────────────────────────
function bootstrapSheets() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  ensureSheet(ss, SHEET_GOS,      ['go_id','name','type','deadline','status','min_secure','created_at','payment_deadline']);
  ensureSheet(ss, SHEET_JOINERS,  ['claim_id','go_id','go_name','sub_item_id','sub_item_name','sub_item_kind','username','email','member_or_version','set_num','qty','assigned_vers','claim_status','payment_status','fulfillment','created_at','updated_at']);
  ensureSheet(ss, SHEET_SHIPPING, ['request_id','username','go_ids','full_name','address1','address2','city','state','postal','country','notes','email','card_count','ems_fee','dom_fee','total_fee','shipped','created_at','items']);
  ensureSheet(ss, SHEET_PAYMENTS, ['payment_id','username','go_id','go_name','amount','method','transaction_id','proof_url','email','status','created_at']);
  ensureSheet(ss, SHEET_LISTINGS,    ['listing_id','name','category','price','image_url','qty','note','status','created_at','variants']);
  ensureSheet(ss, SHEET_SHOP_ORDERS, ['order_id','listing_id','listing_name','username','email','qty','unit_price','payment_status','fulfillment','created_at','updated_at','variant']);
  ensureSheet(ss, SHEET_STORE_ORDERS, ['order_id','go_id','go_name','sub_item_id','sub_item_name','store','album_version','qty','unit_cost','status','notes','created_at','updated_at']);
  ensureSheet(ss, SHEET_GC_ADDED, ['go_id','username']);
  // Per-GO sub-item sheets are created when a GO is created.
}

function ensureSheet(ss, name, headers) {
  let sheet = ss.getSheetByName(name);
  if (!sheet) {
    sheet = ss.insertSheet(name);
    sheet.getRange(1, 1, 1, headers.length).setValues([headers]);
    sheet.getRange(1, 1, 1, headers.length)
      .setFontWeight('bold')
      .setBackground('#F1EFE8');
    sheet.setFrozenRows(1);
  } else {
    // Migrate: append any header columns added to the schema after this sheet
    // was first created (ensures e.g. new 'variants'/'variant' columns exist).
    const lastCol = sheet.getLastColumn();
    const existing = lastCol > 0 ? sheet.getRange(1, 1, 1, lastCol).getValues()[0] : [];
    const missing = headers.filter(h => existing.indexOf(h) === -1);
    if (missing.length) {
      sheet.getRange(1, existing.length + 1, 1, missing.length).setValues([missing]);
      sheet.getRange(1, existing.length + 1, 1, missing.length)
        .setFontWeight('bold').setBackground('#F1EFE8');
    }
  }
  return sheet;
}

// ── HTTP Router ───────────────────────────────────────────────────────────────
function doGet(e) {
  const action = e.parameter.action;
  try {
    let result;
    if      (action === 'getAllGOs')       result = getAllGOs();
    else if (action === 'getJoiners')      result = getJoiners(e.parameter.username);
    else if (action === 'getShipping')     result = getShipping();
    else if (action === 'getPayments')     result = getPayments();
    else if (action === 'getListings')     result = getListings();
    else if (action === 'getShopOrders')   result = getShopOrders();
    else if (action === 'getStoreOrders')  result = getStoreOrders();
    else if (action === 'getGcAdded')      result = getGcAdded();
    else if (action === 'ping')            result = { ok: true };
    else result = { error: 'Unknown action: ' + action };
    return jsonResponse(result);
  } catch(err) {
    return jsonResponse({ error: err.message });
  }
}

function doPost(e) {
  const body = JSON.parse(e.postData.contents);
  const action = body.action;
  try {
    let result;
    if      (action === 'createGO')          result = createGO(body.data);
    else if (action === 'updateGO')          result = updateGO(body.data);
    else if (action === 'deleteGO')          result = deleteGO(body.data.go_id);
    else if (action === 'submitClaim')       result = submitClaim(body.data);
    else if (action === 'updateClaim')       result = updateClaim(body.data);
    else if (action === 'deleteClaim')       result = deleteClaim(body.data.claim_id);
    else if (action === 'secureSet')         result = secureSet(body.data);
    else if (action === 'unsecureSet')       result = unsecureSet(body.data);
    else if (action === 'submitPayment')     result = submitPayment(body.data);
    else if (action === 'updatePayment')     result = updatePayment(body.data);
    else if (action === 'createListing')     result = createListing(body.data);
    else if (action === 'updateListing')     result = updateListing(body.data);
    else if (action === 'deleteListing')     result = deleteListing(body.data.listing_id);
    else if (action === 'placeShopOrder')    result = placeShopOrder(body.data);
    else if (action === 'updateShopOrder')   result = updateShopOrder(body.data);
    else if (action === 'deleteShopOrder')   result = deleteShopOrder(body.data.order_id);
    else if (action === 'createStoreOrder')  result = createStoreOrder(body.data);
    else if (action === 'updateStoreOrder')  result = updateStoreOrder(body.data);
    else if (action === 'deleteStoreOrder')  result = deleteStoreOrder(body.data.order_id);
    else if (action === 'setGcAdded')       result = setGcAdded(body.data);
    else if (action === 'deletePayment')     result = deletePayment(body.data.payment_id);
    else if (action === 'submitShipping')    result = submitShipping(body.data);
    else if (action === 'updateShipping')    result = updateShipping(body.data);
    else if (action === 'bootstrap')         result = { ok: true, msg: bootstrapSheets() || 'Sheets ready' };
    else result = { error: 'Unknown action: ' + action };
    return jsonResponse(result);
  } catch(err) {
    return jsonResponse({ error: err.message });
  }
}

function jsonResponse(data) {
  return ContentService
    .createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}

// ── GOs ───────────────────────────────────────────────────────────────────────
function getAllGOs() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const goSheet = ss.getSheetByName(SHEET_GOS);
  if (!goSheet) return { gos: [] };
  const rows = sheetToObjects(goSheet);
  const gos = rows.map(row => {
    const siSheet = ss.getSheetByName('go_' + row.go_id);
    const subItems = siSheet ? sheetToObjects(siSheet) : [];
    return { ...row, subItems };
  });
  // Also load claims per GO
  const claimSheet = ss.getSheetByName(SHEET_JOINERS);
  const allClaims = claimSheet ? sheetToObjects(claimSheet) : [];
  gos.forEach(go => {
    go.claims = allClaims.filter(c => c.go_id === go.go_id);
  });
  return { gos };
}

function createGO(data) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  bootstrapSheets();
  const goSheet = ss.getSheetByName(SHEET_GOS);
  const goId = data.id || ('go_' + Date.now());
  goSheet.appendRow([goId, data.name, data.type, data.deadline, data.status || 'open', data.min_secure || 7, new Date().toISOString(), data.payment_deadline || '']);
  // Create per-GO sub-items sheet
  const siSheet = ensureSheet(ss, 'go_' + goId, ['sub_item_id','name','kind','members','versions','price','ot_price','min_secure','image_url']);
  (data.subItems || []).forEach(si => {
    siSheet.appendRow([si.id, si.name, si.kind || data.type, JSON.stringify(si.members || []), JSON.stringify(si.versions || []), si.price || 0, si.otPrice || 0, si.minSecure || data.min_secure || 7, si.imageUrl || '']);
  });
  return { ok: true, go_id: goId };
}

function updateGO(data) {
  // Serialize with the same lock claim writes use, so two overlapping updateGO calls (or an
  // updateGO racing a submitClaim) can never interleave the sub-item rewrite and duplicate rows.
  const lock = LockService.getScriptLock();
  try { lock.waitLock(15000); }
  catch (e) { return { ok: false, error: 'busy', message: 'Server busy, please retry.' }; }
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const goSheet = ss.getSheetByName(SHEET_GOS);
    const rows = goSheet.getDataRange().getValues();
    const headers = rows[0];
    const idCol = headers.indexOf('go_id');
    for (let i = 1; i < rows.length; i++) {
      if (rows[i][idCol] === data.go_id) {
        if (data.name)     goSheet.getRange(i+1, headers.indexOf('name')+1).setValue(data.name);
        if (data.deadline) goSheet.getRange(i+1, headers.indexOf('deadline')+1).setValue(data.deadline);
        if (data.status)   goSheet.getRange(i+1, headers.indexOf('status')+1).setValue(data.status);
        const pdCol = headers.indexOf('payment_deadline');
        if (pdCol !== -1 && data.payment_deadline !== undefined) goSheet.getRange(i+1, pdCol+1).setValue(data.payment_deadline);
        break;
      }
    }
    // Update sub-items sheet if provided — write the whole grid IN PLACE with one setValues
    // (no delete-then-append, so there is never a moment with zero rows), then trim any
    // surplus old rows. Dedupe by id defensively so a duplicated payload can't persist.
    if (data.subItems) {
      const HEADERS = ['sub_item_id','name','kind','members','versions','price','ot_price','min_secure','image_url'];
      const siSheetName = 'go_' + data.go_id;
      let siSheet = ss.getSheetByName(siSheetName);
      if (!siSheet) siSheet = ensureSheet(ss, siSheetName, HEADERS);
      const seen = {};
      const grid = [HEADERS];
      (data.subItems || []).forEach(si => {
        if (!si || !si.id || seen[si.id]) return;
        seen[si.id] = true;
        grid.push([si.id, si.name || '', si.kind || '', JSON.stringify(si.members || []), JSON.stringify(si.versions || []), si.price || 0, si.otPrice || 0, si.minSecure || 7, si.imageUrl || '']);
      });
      const oldLast = siSheet.getLastRow();
      if (siSheet.getMaxRows() < grid.length) siSheet.insertRowsAfter(siSheet.getMaxRows(), grid.length - siSheet.getMaxRows());
      siSheet.getRange(1, 1, grid.length, HEADERS.length).setValues(grid);
      if (oldLast > grid.length) siSheet.deleteRows(grid.length + 1, oldLast - grid.length);
    }
    return { ok: true };
  } finally {
    lock.releaseLock();
  }
}

function deleteGO(goId) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  // Remove from _gos
  deleteRowWhere(ss.getSheetByName(SHEET_GOS), 'go_id', goId);
  // Remove all claims
  deleteRowsWhere(ss.getSheetByName(SHEET_JOINERS), 'go_id', goId);
  deleteRowsWhere(ss.getSheetByName(SHEET_GC_ADDED), 'go_id', goId);
  // Delete sub-item sheet
  const siSheet = ss.getSheetByName('go_' + goId);
  if (siSheet) ss.deleteSheet(siSheet);
  return { ok: true };
}

// ── Claims ────────────────────────────────────────────────────────────────────
function isGOClosed(ss, goId) {
  const goSheet = ss.getSheetByName(SHEET_GOS);
  if (!goSheet) return false;
  const rows = goSheet.getDataRange().getValues();
  const headers = rows[0];
  const idCol = headers.indexOf('go_id');
  const statusCol = headers.indexOf('status');
  if (idCol < 0 || statusCol < 0) return false;
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][idCol] === goId) return String(rows[i][statusCol]).toLowerCase() === 'closed';
  }
  return false;
}

function submitClaim(data) {
  bootstrapSheets();
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  // Authoritative guard: refuse claims for a GO that is closed in the sheet, even if
  // the client's cached status is stale (loaded before the GO was closed).
  const firstGoId = (data.claims && data.claims[0] && data.claims[0].go_id) || '';
  if (firstGoId && isGOClosed(ss, firstGoId)) {
    return { ok: false, error: 'closed', message: 'This GO is closed and no longer accepting claims.' };
  }
  // Serialize claim writes so concurrent/stale clients can't book the same set-based slot.
  const lock = LockService.getScriptLock();
  try { lock.waitLock(10000); }
  catch (e) { return { ok: false, error: 'busy', message: 'Server busy, please retry.' }; }
  try {
    const sheet = ss.getSheetByName(SHEET_JOINERS);
    const now = new Date().toISOString();
    const claimIds = [];
    const assignedSetNums = [];

    // Build a taken-slot map from existing rows so the SERVER assigns set_num authoritatively
    // (the client's set_num can be stale). key = go_id|sub_item_id -> { set_num -> {member:true} }.
    const values = sheet.getDataRange().getValues();
    const H = values[0];
    const ci = (name) => H.indexOf(name);
    const taken = {};   // key -> { setNum -> {member:true} }
    const maxSet = {};  // key -> highest set_num seen
    for (let i = 1; i < values.length; i++) {
      const row = values[i];
      const key = row[ci('go_id')] + '|' + row[ci('sub_item_id')];
      const sn = parseInt(row[ci('set_num')], 10) || 0;
      const mem = row[ci('member_or_version')];
      if (!sn || !mem) continue;
      (taken[key] = taken[key] || {});
      (taken[key][sn] = taken[key][sn] || {});
      taken[key][sn][mem] = true;
      maxSet[key] = Math.max(maxSet[key] || 0, sn);
    }
    const markTaken = (key, sn, mem) => {
      (taken[key] = taken[key] || {}); (taken[key][sn] = taken[key][sn] || {});
      taken[key][sn][mem] = true; maxSet[key] = Math.max(maxSet[key] || 0, sn);
    };
    const firstFreeSet = (key, mem) => {
      const t = taken[key] || {};
      let n = 1;
      while (t[n] && t[n][mem]) n++;
      return n;
    };

    // OT full sets: each complete set (all members once) gets its OWN fresh set number.
    // A new OT set starts on the first OT claim, or whenever the current OT set already
    // holds this member. (Previously all OT claims in one submission shared a single
    // number, collapsing e.g. 9 ordered full sets into one set_num.)
    const otState = {}; // key -> { num, seen:{member:true} }
    const freeSetNum = (key, from) => { let n = from; while (taken[key] && taken[key][n]) n++; return n; };

    (data.claims || []).forEach(c => {
      const claimId = 'c_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
      claimIds.push(claimId);
      let setNum = c.set_num || '';
      const isSet = (c.sub_item_kind === 'member' || c.sub_item_kind === 'photocard') && c.member_or_version;
      if (isSet) {
        const key = c.go_id + '|' + c.sub_item_id;
        if (c.assigned_vers === 'OT') {
          let st = otState[key];
          if (!st || st.seen[c.member_or_version]) {
            const startFrom = st ? st.num + 1 : (maxSet[key] || 0) + 1;
            st = otState[key] = { num: freeSetNum(key, startFrom), seen: {} };
          }
          st.seen[c.member_or_version] = true;
          setNum = st.num;
        } else {
          setNum = firstFreeSet(key, c.member_or_version);
        }
        markTaken(key, setNum, c.member_or_version);
      }
      assignedSetNums.push(setNum);
      sheet.appendRow([
        claimId, c.go_id, c.go_name, c.sub_item_id, c.sub_item_name, c.sub_item_kind,
        c.username, c.email || '', c.member_or_version || '', setNum,
        c.qty || 1, c.assigned_vers || '', 'pending', 'unpaid', 'Pending', now, now
      ]);
    });
    return { ok: true, claim_ids: claimIds, set_nums: assignedSetNums };
  } finally {
    lock.releaseLock();
  }
}

function updateClaim(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_JOINERS);
  const rows = sheet.getDataRange().getValues();
  const headers = rows[0];
  const idCol = headers.indexOf('claim_id');
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][idCol] === data.claim_id) {
      if (data.claim_status)   sheet.getRange(i+1, headers.indexOf('claim_status')+1).setValue(data.claim_status);
      if (data.payment_status) sheet.getRange(i+1, headers.indexOf('payment_status')+1).setValue(data.payment_status);
      if (data.fulfillment)    sheet.getRange(i+1, headers.indexOf('fulfillment')+1).setValue(data.fulfillment);
      if (data.set_num)        sheet.getRange(i+1, headers.indexOf('set_num')+1).setValue(data.set_num);
      sheet.getRange(i+1, headers.indexOf('updated_at')+1).setValue(new Date().toISOString());
    }
  }
  return { ok: true };
}

function deleteClaim(claimId) {
  deleteRowWhere(SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_JOINERS), 'claim_id', claimId);
  return { ok: true };
}

function secureSet(data) {
  // Mark all claims in a given go/sub_item/set_num as secured
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_JOINERS);
  const rows = sheet.getDataRange().getValues();
  const headers = rows[0];
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][headers.indexOf('go_id')] === data.go_id &&
        rows[i][headers.indexOf('sub_item_id')] === data.sub_item_id &&
        String(rows[i][headers.indexOf('set_num')]) === String(data.set_num)) {
      sheet.getRange(i+1, headers.indexOf('claim_status')+1).setValue('secured');
      sheet.getRange(i+1, headers.indexOf('updated_at')+1).setValue(new Date().toISOString());
    }
  }
  return { ok: true };
}

function unsecureSet(data) {
  // Revert claim_status for all claims in a given go/sub_item/set_num back to open
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_JOINERS);
  const rows = sheet.getDataRange().getValues();
  const headers = rows[0];
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][headers.indexOf('go_id')] === data.go_id &&
        rows[i][headers.indexOf('sub_item_id')] === data.sub_item_id &&
        String(rows[i][headers.indexOf('set_num')]) === String(data.set_num)) {
      sheet.getRange(i+1, headers.indexOf('claim_status')+1).setValue('');
      sheet.getRange(i+1, headers.indexOf('updated_at')+1).setValue(new Date().toISOString());
    }
  }
  return { ok: true };
}

// ── Payments ──────────────────────────────────────────────────────────────────
function submitPayment(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_PAYMENTS);
  const id = 'pay_' + Date.now();
  sheet.appendRow([id, data.username, data.go_id, data.go_name, data.amount, data.method, data.transaction_id || '', data.proof_url || '', data.email || '', 'pending', new Date().toISOString()]);
  return { ok: true, payment_id: id };
}

function updatePayment(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_PAYMENTS);
  updateRowWhere(sheet, 'payment_id', data.payment_id, { status: data.status });
  if (data.status === 'confirmed') {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const now = new Date().toISOString();
    if (data.go_id === 'shop') {
      const orderSheet = ss.getSheetByName(SHEET_SHOP_ORDERS);
      if (data.paid_order_ids || data.unpaid_order_ids) {
        setPaymentByIds(orderSheet, 'order_id', data.paid_order_ids || [], data.unpaid_order_ids || [], now);
      } else {
        // Fallback (no explicit lists): mark this user's shop orders paid.
        markUserRowsPaid(orderSheet, 'username', data.username, null, null, now);
      }
    } else {
      const claimSheet = ss.getSheetByName(SHEET_JOINERS);
      if (data.paid_claim_ids || data.unpaid_claim_ids) {
        // Frontend computed exactly which claims the payment covers (partial accounting).
        setPaymentByIds(claimSheet, 'claim_id', data.paid_claim_ids || [], data.unpaid_claim_ids || [], now);
      } else {
        // Fallback: mark this user's OWED claims paid (secured set slots + claims-based).
        markUserRowsPaid(claimSheet, 'username', data.username, data.go_id, 'go_id', now);
      }
    }
  }
  return { ok: true };
}

// Set payment_status='paid' for rows whose id is in paidIds, 'unpaid' for unpaidIds.
function setPaymentByIds(sheet, idCol, paidIds, unpaidIds, now) {
  if (!sheet) return;
  const rows = sheet.getDataRange().getValues();
  const headers = rows[0];
  const iCol = headers.indexOf(idCol);
  const payCol = headers.indexOf('payment_status');
  const updCol = headers.indexOf('updated_at');
  const paidSet = {}, unpaidSet = {};
  (paidIds || []).forEach(id => { paidSet[id] = true; });
  (unpaidIds || []).forEach(id => { unpaidSet[id] = true; });
  for (let i = 1; i < rows.length; i++) {
    const id = rows[i][iCol];
    let val = null;
    if (paidSet[id]) val = 'paid';
    else if (unpaidSet[id]) val = 'unpaid';
    if (val !== null) {
      sheet.getRange(i+1, payCol+1).setValue(val);
      if (updCol >= 0) sheet.getRange(i+1, updCol+1).setValue(now);
    }
  }
}

// Fallback marking by username (+ optional go_id): mark OWED rows paid. For joiners,
// skip unsecured set slots. goCol null = no go filter (shop).
function markUserRowsPaid(sheet, userColName, username, goId, goColName, now) {
  if (!sheet) return;
  const rows = sheet.getDataRange().getValues();
  const headers = rows[0];
  const uCol = headers.indexOf(userColName);
  const goCol = goColName ? headers.indexOf(goColName) : -1;
  const setCol = headers.indexOf('set_num');
  const csCol = headers.indexOf('claim_status');
  const payCol = headers.indexOf('payment_status');
  const updCol = headers.indexOf('updated_at');
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][uCol] !== username) continue;
    if (goCol >= 0 && rows[i][goCol] !== goId) continue;
    if (setCol >= 0) {
      const isSetBased = String(rows[i][setCol]).trim() !== '';
      const isSecured = String(rows[i][csCol]).toLowerCase() === 'secured';
      if (isSetBased && !isSecured) continue; // unsecured set slot — not owed
    }
    sheet.getRange(i+1, payCol+1).setValue('paid');
    if (updCol >= 0) sheet.getRange(i+1, updCol+1).setValue(now);
  }
}

function getPayments() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_PAYMENTS);
  return { payments: sheet ? sheetToObjects(sheet) : [] };
}

function getListings() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  return { listings: sheet ? sheetToObjects(sheet) : [] };
}

function getShopOrders() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHOP_ORDERS);
  return { shop_orders: sheet ? sheetToObjects(sheet) : [] };
}

function getStoreOrders() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_STORE_ORDERS);
  return { store_orders: sheet ? sheetToObjects(sheet) : [] };
}

function getGcAdded() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_GC_ADDED);
  return { gc_added: sheet ? sheetToObjects(sheet) : [] };
}

function setGcAdded(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_GC_ADDED);
  const rows = sheet.getDataRange().getValues();
  const h = rows[0];
  const gi = h.indexOf('go_id'), ui = h.indexOf('username');
  const norm = s => String(s == null ? '' : s).trim().toLowerCase();
  let foundRow = -1;
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][gi] === data.go_id && norm(rows[i][ui]) === norm(data.username)) { foundRow = i; break; }
  }
  if (data.added) {
    if (foundRow === -1) sheet.appendRow([data.go_id, data.username]);
  } else if (foundRow !== -1) {
    sheet.deleteRow(foundRow + 1);
  }
  return { ok: true };
}

function createStoreOrder(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_STORE_ORDERS);
  const id = 'sto_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
  const now = new Date().toISOString();
  sheet.appendRow([
    id, data.go_id || '', data.go_name || '', data.sub_item_id || '', data.sub_item_name || '',
    data.store || '', data.album_version || '', data.qty || 0, data.unit_cost || 0,
    data.status || 'Ordered', data.notes || '', now, now
  ]);
  return { ok: true, order_id: id };
}

function updateStoreOrder(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_STORE_ORDERS);
  const fields = {};
  ['go_id','go_name','sub_item_id','sub_item_name','store','album_version','qty','unit_cost','status','notes'].forEach(k => {
    if (data[k] !== undefined) fields[k] = data[k];
  });
  fields.updated_at = new Date().toISOString();
  updateRowWhere(sheet, 'order_id', data.order_id, fields);
  return { ok: true };
}

function deleteStoreOrder(order_id) {
  deleteRowWhere(SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_STORE_ORDERS), 'order_id', order_id);
  return { ok: true };
}

function createListing(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  const id = 'lst_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
  sheet.appendRow([
    id, data.name || '', data.category || '', data.price || 0, data.image_url || '',
    data.qty || 0, data.note || '', 'active', new Date().toISOString(),
    JSON.stringify(data.variants || [])
  ]);
  return { ok: true, listing_id: id };
}

function updateListing(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  const fields = {};
  ['name','category','price','image_url','qty','note','status'].forEach(k => {
    if (data[k] !== undefined) fields[k] = data[k];
  });
  if (data.variants !== undefined) fields.variants = JSON.stringify(data.variants);
  updateRowWhere(sheet, 'listing_id', data.listing_id, fields);
  return { ok: true };
}

function deleteListing(listing_id) {
  // Soft-delete: hide it, preserve order history.
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  updateRowWhere(sheet, 'listing_id', listing_id, { status: 'hidden' });
  return { ok: true };
}

function placeShopOrder(data) {
  bootstrapSheets();
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const listSheet = ss.getSheetByName(SHEET_LISTINGS);
  const rows = listSheet.getDataRange().getValues();
  const headers = rows[0];
  const idCol = headers.indexOf('listing_id');
  const qtyCol = headers.indexOf('qty');
  const nameCol = headers.indexOf('name');
  const priceCol = headers.indexOf('price');
  const want = parseInt(data.qty) || 1;
  const varCol = headers.indexOf('variants');
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][idCol] === data.listing_id) {
      const orderSheet = ss.getSheetByName(SHEET_SHOP_ORDERS);
      const oid = 'sho_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
      const now = new Date().toISOString();
      if (data.variant) {
        // Variant listing: guard + decrement the chosen variant's stock.
        let variants = [];
        try { variants = JSON.parse(rows[i][varCol] || '[]'); } catch (e) { variants = []; }
        const v = variants.find(x => x.name === data.variant);
        const avail = v ? (parseInt(v.qty) || 0) : 0;
        if (!v || avail < want) return { ok: false, error: 'oversold', available: avail };
        v.qty = avail - want;
        listSheet.getRange(i+1, varCol+1).setValue(JSON.stringify(variants));
        orderSheet.appendRow([
          oid, data.listing_id, rows[i][nameCol], data.username, data.email || '',
          want, rows[i][priceCol], 'unpaid', 'Pending', now, now, data.variant
        ]);
        return { ok: true, order_id: oid };
      }
      // Simple listing: single qty column.
      const have = parseInt(rows[i][qtyCol]) || 0;
      if (have < want) return { ok: false, error: 'oversold', available: have };
      listSheet.getRange(i+1, qtyCol+1).setValue(have - want);
      orderSheet.appendRow([
        oid, data.listing_id, rows[i][nameCol], data.username, data.email || '',
        want, rows[i][priceCol], 'unpaid', 'Pending', now, now, ''
      ]);
      return { ok: true, order_id: oid };
    }
  }
  return { ok: false, error: 'not_found' };
}

function updateShopOrder(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHOP_ORDERS);
  const fields = {};
  if (data.payment_status !== undefined) fields.payment_status = data.payment_status;
  if (data.fulfillment !== undefined)    fields.fulfillment = data.fulfillment;
  fields.updated_at = new Date().toISOString();
  updateRowWhere(sheet, 'order_id', data.order_id, fields);
  return { ok: true };
}

// ── Shipping ──────────────────────────────────────────────────────────────────
function submitShipping(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHIPPING);
  const id = 'ship_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
  const items = data.items || [];
  sheet.appendRow([id, data.username, data.go_ids || '', data.full_name || '', data.address1 || '', data.address2 || '', data.city || '', data.state || '', data.postal || '', data.country || '', data.notes || '', data.email || '', items.length, '', '', '', false, new Date().toISOString(), JSON.stringify(items)]);
  return { ok: true, request_id: id };
}

function updateShipping(data) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sheet = ss.getSheetByName(SHEET_SHIPPING);
  const fields = {};
  if (data.ems_fee !== undefined)   fields.ems_fee = data.ems_fee;
  if (data.dom_fee !== undefined)   fields.dom_fee = data.dom_fee;
  if (data.total_fee !== undefined) fields.total_fee = data.total_fee;
  if (data.shipped !== undefined)   fields.shipped = data.shipped;
  updateRowWhere(sheet, 'request_id', data.request_id, fields);
  if (data.shipped === true) {
    // Read the request's bundled items and mark each shipped.
    const rows = sheet.getDataRange().getValues();
    const headers = rows[0];
    const ridCol = headers.indexOf('request_id');
    const itemsCol = headers.indexOf('items');
    let items = [];
    for (let i = 1; i < rows.length; i++) {
      if (rows[i][ridCol] === data.request_id) {
        try { items = JSON.parse(rows[i][itemsCol] || '[]'); } catch (e) { items = []; }
        break;
      }
    }
    const claimIds = items.filter(it => it.type === 'claim').map(it => it.id);
    const orderIds = items.filter(it => it.type === 'shop').map(it => it.id);
    if (claimIds.length) setFulfillmentByIds(ss.getSheetByName(SHEET_JOINERS), 'claim_id', claimIds, 'Shipped');
    if (orderIds.length) setFulfillmentByIds(ss.getSheetByName(SHEET_SHOP_ORDERS), 'order_id', orderIds, 'Shipped');
  }
  return { ok: true };
}

function setFulfillmentByIds(sheet, idCol, ids, value) {
  if (!sheet || !ids.length) return;
  const rows = sheet.getDataRange().getValues();
  const headers = rows[0];
  const iCol = headers.indexOf(idCol);
  const fCol = headers.indexOf('fulfillment');
  const uCol = headers.indexOf('updated_at');
  const idSet = {};
  ids.forEach(id => { idSet[id] = true; });
  for (let i = 1; i < rows.length; i++) {
    if (idSet[rows[i][iCol]]) {
      if (fCol >= 0) sheet.getRange(i+1, fCol+1).setValue(value);
      if (uCol >= 0) sheet.getRange(i+1, uCol+1).setValue(new Date().toISOString());
    }
  }
}

function getShipping() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHIPPING);
  return { requests: sheet ? sheetToObjects(sheet) : [] };
}

function getJoiners(username) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_JOINERS);
  if (!sheet) return { claims: [] };
  const all = sheetToObjects(sheet);
  return { claims: username ? all.filter(c => c.username === username || c.username === '@' + username) : all };
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function sheetToObjects(sheet) {
  const data = sheet.getDataRange().getValues();
  if (data.length < 2) return [];
  const headers = data[0];
  return data.slice(1).map(row => {
    const obj = {};
    headers.forEach((h, i) => { obj[h] = row[i]; });
    return obj;
  });
}

function deleteShopOrder(order_id) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const orderSheet = ss.getSheetByName(SHEET_SHOP_ORDERS);
  const rows = orderSheet.getDataRange().getValues();
  const headers = rows[0];
  const oidCol = headers.indexOf('order_id');
  const lidCol = headers.indexOf('listing_id');
  const qtyCol = headers.indexOf('qty');
  const varCol = headers.indexOf('variant');
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][oidCol] === order_id) {
      restoreListingStock(ss, rows[i][lidCol], parseInt(rows[i][qtyCol]) || 0, rows[i][varCol]);
      break;
    }
  }
  deleteRowWhere(orderSheet, 'order_id', order_id);
  return { ok: true };
}

function restoreListingStock(ss, listing_id, qty, variant) {
  const listSheet = ss.getSheetByName(SHEET_LISTINGS);
  if (!listSheet) return;
  const rows = listSheet.getDataRange().getValues();
  const headers = rows[0];
  const idCol = headers.indexOf('listing_id');
  const qtyCol = headers.indexOf('qty');
  const varCol = headers.indexOf('variants');
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][idCol] === listing_id) {
      if (variant) {
        let variants = [];
        try { variants = JSON.parse(rows[i][varCol] || '[]'); } catch (e) { variants = []; }
        const v = variants.find(x => x.name === variant);
        if (v) {
          v.qty = (parseInt(v.qty) || 0) + qty;
          listSheet.getRange(i+1, varCol+1).setValue(JSON.stringify(variants));
        }
      } else {
        listSheet.getRange(i+1, qtyCol+1).setValue((parseInt(rows[i][qtyCol]) || 0) + qty);
      }
      return;
    }
  }
}

function deletePayment(payment_id) {
  deleteRowWhere(SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_PAYMENTS), 'payment_id', payment_id);
  return { ok: true };
}

function deleteRowWhere(sheet, col, val) {
  if (!sheet) return;
  const rows = sheet.getDataRange().getValues();
  const colIdx = rows[0].indexOf(col);
  for (let i = rows.length - 1; i >= 1; i--) {
    if (rows[i][colIdx] === val) sheet.deleteRow(i + 1);
  }
}

function deleteRowsWhere(sheet, col, val) { deleteRowWhere(sheet, col, val); }

function updateRowWhere(sheet, col, val, updates) {
  if (!sheet) return;
  const rows = sheet.getDataRange().getValues();
  const headers = rows[0];
  const colIdx = headers.indexOf(col);
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][colIdx] === val) {
      Object.entries(updates).forEach(([k, v]) => {
        if (v !== undefined && v !== null) {
          const idx = headers.indexOf(k);
          if (idx >= 0) sheet.getRange(i+1, idx+1).setValue(v);
        }
      });
    }
  }
}
