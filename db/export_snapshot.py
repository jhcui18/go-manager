#!/usr/bin/env python3
"""Dump the xlsx in legacy API shapes for the parity harness."""
import json, os
from openpyxl import load_workbook
from migrate_from_xlsx import XLSX, rows_as_dicts, parse_members, resolve_go_sheets, parse_int

def main():
    wb = load_workbook(XLSX)
    gos = rows_as_dicts(wb['_gos'])
    joiners = [c for c in rows_as_dicts(wb['joiners']) if c.get('claim_id')]
    sheets = resolve_go_sheets(wb, gos, joiners)
    out = {
        'gos': [],
        'claims': [{k: (str(v) if v is not None else '') for k, v in c.items()} for c in joiners],
        'secured_sets': rows_as_dicts(wb['secured_sets']),
        'closed_subitems': rows_as_dicts(wb['closed_subitems']),
    }
    for g in gos:
        ws = sheets.get(g['go_id'])
        out['gos'].append({
            'go_id': g['go_id'], 'name': g['name'], 'type': g.get('type') or 'photocard',
            'status': g.get('status') or 'open',
            'min_secure': parse_int(g.get('min_secure')) or 7,
            'subItems': [
                {k: (str(v) if v is not None else '') for k, v in r.items()}
                for r in (rows_as_dicts(ws) if ws is not None else [])
            ]
        })
    dst = os.path.join(os.path.dirname(__file__), '..', 'tests', 'fixtures', 'snapshot.json')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'w') as f:
        json.dump(out, f, default=str)
    print('wrote', dst)

if __name__ == '__main__':
    main()
