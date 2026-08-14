from migrate_from_xlsx import build_sets_from_claims

def c(cid, user, member, set_num, created, ot=False):
    return {'claim_id': cid, 'username': user, 'member_or_version': member,
            'set_num': set_num, 'created_at': created,
            'assigned_vers': 'OT' if ot else ''}

MEMBERS = ['A', 'B', 'C']

def test_simple_placement():
    a = build_sets_from_claims([c('1', 'u1', 'A', 1, 't1')], MEMBERS)
    assert a == {'1': 1}

def test_collision_spills_to_next_set():
    a = build_sets_from_claims(
        [c('1', 'u1', 'A', 1, 't1'), c('2', 'u2', 'A', 1, 't2')], MEMBERS)
    assert a == {'1': 1, '2': 2}

def test_earliest_wins_regardless_of_row_order():
    a = build_sets_from_claims(
        [c('2', 'u2', 'A', 1, 't2'), c('1', 'u1', 'A', 1, 't1')], MEMBERS)
    assert a == {'1': 1, '2': 2}

def test_ot_set_is_atomic_and_reserved():
    claims = [c('o1', 'u1', 'A', 1, 't1', ot=True), c('o2', 'u1', 'B', 1, 't1', ot=True),
              c('i1', 'u2', 'C', 1, 't2')]
    a = build_sets_from_claims(claims, MEMBERS)
    assert a['o1'] == a['o2'] == 1
    assert a['i1'] == 2          # individual never enters the OT set

def test_two_ot_full_sets_get_distinct_numbers():
    claims = [c('o1', 'u1', 'A', 1, 't1', ot=True),
              c('o2', 'u1', 'A', 2, 't1', ot=True)]   # second full set, declared 2
    a = build_sets_from_claims(claims, MEMBERS)
    assert a['o1'] != a['o2']

def test_tiebreak_by_claim_id_when_same_timestamp():
    a = build_sets_from_claims(
        [c('b', 'u2', 'A', 1, 't1'), c('a', 'u1', 'A', 1, 't1')], MEMBERS)
    assert a == {'a': 1, 'b': 2}

def test_ot_slot_collision_later_claim_wins_earlier_vanishes():
    # Two OT claims, same user + same declared set + same member slot: JS is
    # slot-based (index.html:5224-5230) so the later claim (by created_at,
    # then claim_id) overwrites the slot and the earlier claim is simply never
    # placed — it must NOT appear in the assignment at all.
    a = build_sets_from_claims(
        [c('c1', 'u1', 'A', 2, 't1', ot=True), c('c10', 'u1', 'A', 2, 't1', ot=True)], MEMBERS)
    assert a == {'c10': 2}
    assert 'c1' not in a
