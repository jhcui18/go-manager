// ── GO Manager — Google Apps Script Backend ──────────────────────────────────
// Deploy as Web App: Execute as "Me", Access "Anyone"
// Paste your deployed Web App URL into the frontend app settings.

const SHEET_ID = SpreadsheetApp.getActiveSpreadsheet().getId();

// ── Sheet name constants ──────────────────────────────────────────────────────
const SHEET_GOS       = '_gos';        // master GO registry
const SHEET_JOINERS   = 'joiners';     // all claims across GOs
const SHEET_SHIPPING  = 'shipping';    // shipping requests
const SHEET_PAYMENTS  = 'payments';    // payment proof submissions

// ── Bootstrap: create all required sheets if missing ─────────────────────────
function bootstrapSheets() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  ensureSheet(ss, SHEET_GOS,      ['go_id','name','type','deadline','status','min_secure','created_at']);
  ensureSheet(ss, SHEET_JOINERS,  ['claim_id','go_id','go_name','sub_item_id','sub_item_name','sub_item_kind','username','email','member_or_version','set_num','qty','assigned_vers','claim_status','payment_status','fulfillment','created_at','updated_at']);
  ensureSheet(ss, SHEET_SHIPPING, ['request_id','username','go_ids','full_name','address1','address2','city','state','postal','country','notes','email','card_count','ems_fee','dom_fee','total_fee','shipped','created_at']);
  ensureSheet(ss, SHEET_PAYMENTS, ['payment_id','username','go_id','go_name','amount','method','transaction_id','proof_url','email','status','created_at']);
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
    else if (action === 'submitPayment')     result = submitPayment(body.data);
    else if (action === 'updatePayment')     result = updatePayment(body.data);
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
  goSheet.appendRow([goId, data.name, data.type, data.deadline, data.status || 'open', data.min_secure || 7, new Date().toISOString()]);
  // Create per-GO sub-items sheet
  const siSheet = ensureSheet(ss, 'go_' + goId, ['sub_item_id','name','kind','members','versions','price','min_secure']);
  (data.subItems || []).forEach(si => {
    siSheet.appendRow([si.id, si.name, si.kind || data.type, JSON.stringify(si.members || []), JSON.stringify(si.versions || []), si.price || 0, si.minSecure || data.min_secure || 7]);
  });
  return { ok: true, go_id: goId };
}

function updateGO(data) {
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
      break;
    }
  }
  // Update sub-items sheet if provided
  if (data.subItems) {
    const siSheetName = 'go_' + data.go_id;
    let siSheet = ss.getSheetByName(siSheetName);
    if (!siSheet) siSheet = ensureSheet(ss, siSheetName, ['sub_item_id','name','kind','members','versions','price','min_secure']);
    // Clear and rewrite (simple approach — sub-items rarely change)
    const lastRow = siSheet.getLastRow();
    if (lastRow > 1) siSheet.getRange(2, 1, lastRow - 1, siSheet.getLastColumn()).clearContent();
    data.subItems.forEach(si => {
      siSheet.appendRow([si.id, si.name, si.kind || '', JSON.stringify(si.members || []), JSON.stringify(si.versions || []), si.price || 0, si.minSecure || 7]);
    });
  }
  return { ok: true };
}

function deleteGO(goId) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  // Remove from _gos
  deleteRowWhere(ss.getSheetByName(SHEET_GOS), 'go_id', goId);
  // Remove all claims
  deleteRowsWhere(ss.getSheetByName(SHEET_JOINERS), 'go_id', goId);
  // Delete sub-item sheet
  const siSheet = ss.getSheetByName('go_' + goId);
  if (siSheet) ss.deleteSheet(siSheet);
  return { ok: true };
}

// ── Claims ────────────────────────────────────────────────────────────────────
function submitClaim(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_JOINERS);
  const now = new Date().toISOString();
  const claimIds = [];
  // data.claims is an array of individual slot claims — each gets its own unique ID
  (data.claims || []).forEach(c => {
    const claimId = 'c_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
    claimIds.push(claimId);
    sheet.appendRow([
      claimId, c.go_id, c.go_name, c.sub_item_id, c.sub_item_name, c.sub_item_kind,
      c.username, c.email || '', c.member_or_version || '', c.set_num || '',
      c.qty || 1, c.assigned_vers || '', 'pending', 'unpaid', 'Pending', now, now
    ]);
  });
  return { ok: true, claim_ids: claimIds };
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
    // Mark all matching claims as paid
    const claimSheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_JOINERS);
    const rows = claimSheet.getDataRange().getValues();
    const headers = rows[0];
    for (let i = 1; i < rows.length; i++) {
      if (rows[i][headers.indexOf('username')] === data.username && rows[i][headers.indexOf('go_id')] === data.go_id) {
        claimSheet.getRange(i+1, headers.indexOf('payment_status')+1).setValue('paid');
        claimSheet.getRange(i+1, headers.indexOf('updated_at')+1).setValue(new Date().toISOString());
      }
    }
  }
  return { ok: true };
}

function getPayments() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_PAYMENTS);
  return { payments: sheet ? sheetToObjects(sheet) : [] };
}

// ── Shipping ──────────────────────────────────────────────────────────────────
function submitShipping(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHIPPING);
  const id = 'ship_' + Date.now();
  sheet.appendRow([id, data.username, data.go_ids || '', data.full_name, data.address1, data.address2 || '', data.city, data.state, data.postal, data.country, data.notes || '', data.email || '', data.card_count || 0, '', '', '', false, new Date().toISOString()]);
  return { ok: true, request_id: id };
}

function updateShipping(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHIPPING);
  updateRowWhere(sheet, 'request_id', data.request_id, {
    ems_fee: data.ems_fee,
    dom_fee: data.dom_fee,
    total_fee: data.total_fee,
    shipped: data.shipped
  });
  return { ok: true };
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
