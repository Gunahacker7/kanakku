// v1.1 tests, mapped to the final_spec §7 checklist. Every test
// name carries its checklist ID. Device-only items (biometric
// prompt, lock-screen rendering, a real v1.0.4 app) are NOT here —
// they are reported NOT-RUN, never faked.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/backup.dart';
import 'package:kanakku/budget_alerts.dart';
import 'package:kanakku/manual.dart';
import 'package:kanakku/money.dart';
import 'package:kanakku/recurring.dart';
import 'package:kanakku/settings.dart';
import 'package:kanakku_parser/kanakku_parser.dart';
import 'package:kanakku_parser/categorize.dart';

// ---- helpers ------------------------------------------------------

ParsedTransaction cap({
  required double amount,
  TxnDirection dir = TxnDirection.debit,
  String? last4 = '1234',
  String? party,
  String? ref,
  required DateTime at,
}) => ParsedTransaction(
  amount: amount,
  direction: dir,
  source: TxnSource.sms,
  receivedAt: at,
  rawBody: 'bank message $amount ${at.millisecondsSinceEpoch} $ref',
  counterparty: party,
  accountLast4: last4,
  upiRef: ref,
  bankHint: 'Bank',
);

Map<String, dynamic> mkRule({
  String id = 'rec_a_1',
  String label = 'Rent',
  int amountPaise = 1000000, // ₹10,000
  String dir = 'debit',
  String matchText = 'landlord',
  String? last4 = '1234',
  String policy = 'matchOrPost',
  int grace = 3,
  Map<String, dynamic>? interval,
  String start = '2026-11-05',
  String? endDate,
  int? maxCount,
}) => newRule(
  id: id,
  label: label,
  amountPaise: amountPaise,
  dir: dir,
  category: 'Rent',
  bucket: 'needs',
  mode: 'UPI',
  interval: interval ?? {'type': 'monthly', 'every': 1, 'dayOfMonth': 5},
  startDate: start,
  matchText: matchText,
  accountLast4: last4,
  capturePolicy: policy,
  graceDays: grace,
  endDate: endDate,
  maxCount: maxCount,
  nowMs: 0,
);

Map<String, dynamic> mkDoc(List<Map<String, dynamic>> rules) =>
    decodeRecurringStore(jsonEncode({'nextRuleSeq': 99, 'rules': rules}));

RecurringPassResult runPass(
  Map<String, dynamic> doc,
  List<Map<String, dynamic>> maps,
  List<ParsedTransaction> caps,
  DateTime now, {
  Set<String> removed = const {},
}) => runRecurringPass(
  store: doc,
  manualMaps: maps,
  captures: caps,
  removedIds: removed,
  now: now,
);

Map<String, dynamic> theRule(RecurringPassResult r, [int i = 0]) =>
    rulesOf(r.store)[i];

List<Map<String, dynamic>> occs(RecurringPassResult r, [int i = 0]) =>
    occurrencesOf(theRule(r, i));

void main() {
  group('money (spec §1)', () {
    test('T-M1: 19.99 rupees is exactly 1999 paise', () {
      expect(paiseFromRupees(19.99), 1999);
      expect(rupeesFromPaise(1999), 19.99);
    });

    test('T-M2: 0.1 + 0.2 rupees is exactly 30 paise', () {
      expect(paiseFromRupees(0.1 + 0.2), 30);
    });

    test('T-M3: integer paise sums never drift', () {
      final parts = [0.1, 0.2, 19.99, 0.01];
      final sumPaise = parts.map(paiseFromRupees).fold(0, (a, b) => a + b);
      expect(sumPaise, paiseFromRupees(20.30));
    });

    test('T-M4: editing an entry recomputes amountPaise atomically', () {
      final map = manualToJson(
        amount: 100,
        label: 'Groceries',
        at: DateTime(2026, 11, 1, 12),
        direction: TxnDirection.debit,
      );
      // Dual-amount invariant: both fields, same write.
      expect(map['amount'], 100.0);
      expect(map['amountPaise'], 10000);
      applyManualEdit(map, amount: 250.50);
      expect(map['amount'], 250.50);
      expect(map['amountPaise'], 25050);
      // List and totals read through the loader agree.
      expect(manualTxnFromJson(map).amount, 250.50);
      expect(manualAmountPaise(map), 25050);
    });

    test('T-M4b: loader rule — amountPaise wins, legacy converts', () {
      final legacy = {
        'amount': 42.50,
        'label': 'Old',
        'ts': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      };
      expect(manualAmountPaise(legacy), 4250);
      final both = {...legacy, 'amount': 1.0, 'amountPaise': 777};
      expect(manualAmountPaise(both), 777);
      expect(manualTxnFromJson(both).amount, 7.77);
    });
  });

  group('schedule maths (spec §3.4)', () {
    test('T-R1: monthly on the 31st clamps, never drifts', () {
      final r = mkRule(
        start: '2026-01-31',
        interval: {'type': 'monthly', 'every': 1, 'dayOfMonth': 31},
      );
      expect(dueDates(r, '2026-01-01', '2026-04-30'), [
        '2026-01-31',
        '2026-02-28',
        '2026-03-31',
        '2026-04-30',
      ]);
    });

    test('T-R2: weekly every 2 weeks; customDays every 10', () {
      final w = mkRule(
        start: '2026-01-07', // a Wednesday
        interval: {'type': 'weekly', 'every': 2, 'weekday': 3},
      );
      expect(dueDates(w, '2026-01-01', '2026-02-28'), [
        '2026-01-07',
        '2026-01-21',
        '2026-02-04',
        '2026-02-18',
      ]);
      final c = mkRule(
        start: '2026-01-01',
        interval: {'type': 'customDays', 'every': 10},
      );
      expect(dueDates(c, '2025-12-31', '2026-01-31'), [
        '2026-01-01',
        '2026-01-11',
        '2026-01-21',
        '2026-01-31',
      ]);
    });
  });

  group('matching (spec §3.2)', () {
    test('grouping: (paise, last4, date) — twins share a group', () {
      final a = viewOf(
        cap(amount: 10000, ref: 'R1', at: DateTime(2026, 11, 5, 9)),
      );
      final b = viewOf(
        cap(amount: 10000, ref: 'R2', at: DateTime(2026, 11, 5, 18)),
      );
      final other = viewOf(
        cap(
          amount: 10000,
          last4: '9999',
          ref: 'R3',
          at: DateTime(2026, 11, 5, 9),
        ),
      );
      final groups = groupCaptures([a, b, other]);
      expect(groups.length, 2);
      expect(groups[captureGroupKey(a)]!.length, 2);
    });

    test('T-R6b premise: SMS/notification twins share one dedupeKey', () {
      final sms = cap(amount: 10000, ref: 'SAME', at: DateTime(2026, 11, 5));
      final notif = cap(amount: 10000, ref: 'SAME', at: DateTime(2026, 11, 5));
      expect(sms.dedupeKey, notif.dedupeKey);
    });

    test('match clauses: counterparty, last4, direction, window', () {
      final rule = mkRule();
      final good = viewOf(
        cap(amount: 10000, party: 'Paid to LANDLORD', at: DateTime(2026, 11, 5)),
      );
      expect(captureMatches(rule, 1000000, good), isTrue);
      final noParty = viewOf(cap(amount: 10000, at: DateTime(2026, 11, 5)));
      expect(captureMatches(rule, 1000000, noParty), isTrue);
      final wrongParty = viewOf(
        cap(amount: 10000, party: 'Someone else', at: DateTime(2026, 11, 5)),
      );
      expect(captureMatches(rule, 1000000, wrongParty), isFalse);
      final wrongAcct = viewOf(
        cap(
          amount: 10000,
          last4: '9999',
          party: 'landlord',
          at: DateTime(2026, 11, 5),
        ),
      );
      expect(captureMatches(rule, 1000000, wrongAcct), isFalse);
      expect(inMatchWindow('2026-11-02', '2026-11-05', 3), isTrue);
      expect(inMatchWindow('2026-11-01', '2026-11-05', 3), isFalse);
      expect(inMatchWindow('2026-11-08', '2026-11-05', 3), isTrue);
      expect(inMatchWindow('2026-11-09', '2026-11-05', 3), isFalse);
    });

    test('T-R17: empty matchText matches nothing', () {
      final rule = mkRule(matchText: '');
      final c = viewOf(
        cap(amount: 10000, party: 'landlord', at: DateTime(2026, 11, 5)),
      );
      expect(captureMatches(rule, 1000000, c), isFalse);
    });

    test('T-R18: graceDays clamped to 0..14 on read', () {
      final hi = decodeRecurringStore(
        jsonEncode({
          'nextRuleSeq': 1,
          'rules': [
            {...mkRule(), 'graceDays': 99},
          ],
        }),
      );
      expect(rulesOf(hi).single['graceDays'], 14);
      final lo = decodeRecurringStore(
        jsonEncode({
          'nextRuleSeq': 1,
          'rules': [
            {...mkRule(), 'graceDays': -5},
          ],
        }),
      );
      expect(rulesOf(lo).single['graceDays'], 0);
    });
  });

  group('engine pass (spec §3.3)', () {
    test('T-R6: a matching capture satisfies the occurrence once', () {
      final res = runPass(mkDoc([mkRule()]), [], [
        cap(amount: 10000, party: 'LANDLORD', at: DateTime(2026, 11, 5, 10)),
      ], DateTime(2026, 11, 6));
      expect(occs(res).single['state'], 'matched');
      expect(occs(res).single['captureKey'], isNotNull);
      expect(theRule(res)['firedCount'], 1);
      expect(res.manualMaps, isEmpty); // counted once, via the capture
    });

    test('T-R7: no match by D+g+1 posts an entry dated the due date', () {
      final res = runPass(mkDoc([mkRule()]), [], [], DateTime(2026, 11, 9));
      expect(occs(res).single['state'], 'posted');
      expect(res.manualMaps.length, 1);
      final m = res.manualMaps.single;
      expect(m['origin'], 'recurring');
      expect(m['amount'], 10000.0);
      expect(m['amountPaise'], 1000000);
      final ts = DateTime.fromMillisecondsSinceEpoch(m['ts'] as int);
      expect((ts.year, ts.month, ts.day, ts.hour), (2026, 11, 5, 12));
    });

    test('T-R3: 45-day catch-up = one back-post + today pending', () {
      final rule = mkRule(
        start: '2026-09-23',
        interval: {'type': 'monthly', 'every': 1, 'dayOfMonth': 7},
      );
      final res = runPass(mkDoc([rule]), [], [], DateTime(2026, 11, 7));
      expect(res.manualMaps.length, 1); // Oct 7 back-posted
      expect(
        occs(res).map((o) => o['state']),
        containsAllInOrder(['posted', 'pending']),
      );
      final ts = DateTime.fromMillisecondsSinceEpoch(
        res.manualMaps.single['ts'] as int,
      );
      expect(ts.hour, 12); // stamped at noon on the due date
    });

    test('T-R4: occurrences older than 90 days are skipped, never posted', () {
      final rule = mkRule(
        start: '2025-11-07',
        policy: 'auto',
        interval: {'type': 'monthly', 'every': 1, 'dayOfMonth': 7},
      );
      final res = runPass(mkDoc([rule]), [], [], DateTime(2026, 11, 7));
      expect(res.manualMaps.length, 3); // Sep 7, Oct 7, Nov 7 2026
      expect(
        occs(res).where((o) => o['state'] == 'skipped').length,
        10, // Nov 2025 .. Aug 2026
      );
      expect(res.notices, isNotEmpty);
      for (final m in res.manualMaps) {
        expect(m['occurrenceDate'], isNot(startsWith('2025')));
      }
    });

    test('T-R5: a second pass — and a crash mid-pass — never duplicate', () {
      final first = runPass(mkDoc([mkRule()]), [], [], DateTime(2026, 11, 9));
      expect(first.manualMaps.length, 1);
      final second = runPass(
        first.store,
        first.manualMaps,
        [],
        DateTime(2026, 11, 10),
      );
      expect(second.manualMaps.length, 1);
      expect(theRule(second)['firedCount'], 1);
      // Crash simulation: the entry reached the store but the
      // occurrence still says pending — healing recognises it.
      final crashedDoc = mkDoc([mkRule()]);
      final healed = runPass(
        crashedDoc,
        first.manualMaps,
        [],
        DateTime(2026, 11, 9),
      );
      expect(healed.manualMaps.length, 1);
      expect(occs(healed).single['state'], 'posted');
    });

    test('T-R6c: two distinct same-amount payments flag, neither consumed', () {
      final caps = [
        cap(amount: 10000, party: 'landlord', ref: 'A', at: DateTime(2026, 11, 5, 9)),
        cap(amount: 10000, party: 'landlord', ref: 'B', at: DateTime(2026, 11, 5, 18)),
      ];
      final res = runPass(mkDoc([mkRule()]), [], caps, DateTime(2026, 11, 6));
      expect(occs(res).single['state'], 'flagged');
      expect(occs(res).single['flagReason'], 'ambiguousMatch');
      expect(theRule(res)['firedCount'], 0);
      expect(res.manualMaps, isEmpty);
      // Resolution consumes exactly one.
      final key = entryId(caps.first);
      expect(
        resolveFlaggedMatch(res.store, 'rec_a_1', '2026-11-05', key),
        isTrue,
      );
      final after = rulesOf(res.store).single;
      expect(occurrencesOf(after).single['state'], 'matched');
      expect(after['firedCount'], 1);
    });

    test('T-R10: two identical rules — earliest due date consumes', () {
      final a = mkRule(id: 'rec_a_1');
      final b = mkRule(
        id: 'rec_b_2',
        interval: {'type': 'monthly', 'every': 1, 'dayOfMonth': 6},
        start: '2026-11-06',
      );
      final res = runPass(mkDoc([a, b]), [], [
        cap(amount: 10000, party: 'landlord', at: DateTime(2026, 11, 5, 10)),
      ], DateTime(2026, 11, 6));
      expect(occs(res, 0).single['state'], 'matched');
      expect(occs(res, 1).single['state'], 'pending');
    });

    test('T-R10b: a captureKey-consumed capture is never re-consumed', () {
      final caps = [
        cap(amount: 10000, party: 'landlord', at: DateTime(2026, 11, 5, 10)),
      ];
      final first = runPass(mkDoc([mkRule()]), [], caps, DateTime(2026, 11, 6));
      expect(occs(first).single['state'], 'matched');
      final doc2 = mkDoc([
        rulesOf(first.store).single,
        mkRule(
          id: 'rec_b_2',
          interval: {'type': 'monthly', 'every': 1, 'dayOfMonth': 6},
          start: '2026-11-06',
        ),
      ]);
      final second = runPass(doc2, [], caps, DateTime(2026, 11, 6));
      expect(occs(second, 1).single['state'], 'pending');
    });

    test('T-R11: pause = skip — paused dates never fire or catch up', () {
      final rule = mkRule(
        policy: 'auto',
        start: '2026-10-08',
        interval: {'type': 'customDays', 'every': 10},
      );
      rule['lastCreatedDate'] = '2026-10-08';
      rule['firedCount'] = 1;
      rule['pauseSpans'] = [
        {'from': '2026-10-15', 'to': '2026-11-01'},
      ];
      rule['occurrences'] = [
        {'date': '2026-10-08', 'amountPaise': 1000000, 'state': 'posted'},
      ];
      final res = runPass(mkDoc([rule]), [], [], DateTime(2026, 11, 7));
      final states = {for (final o in occs(res)) o['date']: o['state']};
      expect(states['2026-10-18'], 'skipped');
      expect(states['2026-10-28'], 'skipped');
      expect(states['2026-11-07'], 'posted');
      expect(theRule(res)['firedCount'], 2); // skips never fire
      expect(res.manualMaps.length, 1); // only Nov 7 posted
    });

    test('T-R12: matching and posting use the occurrence SNAPSHOT', () {
      final rule = mkRule(amountPaise: 1200000); // rule now ₹12,000
      rule['lastCreatedDate'] = '2026-11-05';
      rule['occurrences'] = [
        {'date': '2026-11-05', 'amountPaise': 1000000, 'state': 'pending'},
      ];
      // A ₹10,000 capture (the snapshot) matches; ₹12,000 would not.
      final matched = runPass(mkDoc([rule]), [], [
        cap(amount: 10000, party: 'landlord', at: DateTime(2026, 11, 5)),
      ], DateTime(2026, 11, 6));
      expect(occs(matched).single['state'], 'matched');
      // And posting uses the snapshot amount too.
      final posted = runPass(mkDoc([rule]), [], [], DateTime(2026, 11, 9));
      expect(posted.manualMaps.single['amount'], 10000.0);
    });

    test('T-R13: a matched capture later removed never re-posts', () {
      final caps = [
        cap(amount: 10000, party: 'landlord', at: DateTime(2026, 11, 5)),
      ];
      final first = runPass(mkDoc([mkRule()]), [], caps, DateTime(2026, 11, 6));
      expect(occs(first).single['state'], 'matched');
      final second = runPass(
        first.store,
        first.manualMaps,
        [], // capture removed from the world
        DateTime(2026, 11, 20),
      );
      expect(occs(second).single['state'], 'matched');
      expect(second.manualMaps, isEmpty);
    });

    test('T-R14: credit rules match, or flag for manual posting', () {
      final salary = mkRule(
        id: 'rec_s_1',
        label: 'Salary',
        amountPaise: 5000000,
        dir: 'credit',
        matchText: 'ACME',
        last4: null,
        start: '2026-11-01',
        interval: {'type': 'monthly', 'every': 1, 'dayOfMonth': 1},
      );
      final matched = runPass(mkDoc([salary]), [], [
        cap(
          amount: 50000,
          dir: TxnDirection.credit,
          party: 'ACME CORP',
          last4: null,
          at: DateTime(2026, 11, 1),
        ),
      ], DateTime(2026, 11, 2));
      expect(occs(matched).single['state'], 'matched');
      expect(matched.manualMaps, isEmpty);

      final unseen = runPass(mkDoc([salary]), [], [], DateTime(2026, 11, 7));
      expect(occs(unseen).single['state'], 'flagged');
      expect(occs(unseen).single['flagReason'], 'creditUnseen');
      expect(unseen.manualMaps, isEmpty); // NO entry until the user taps
      expect(
        postFlaggedOccurrence(
          unseen.store,
          unseen.manualMaps,
          'rec_s_1',
          '2026-11-01',
          DateTime(2026, 11, 7),
        ),
        isTrue,
      );
      expect(unseen.manualMaps.length, 1);
    });

    test('T-R15: maxCount=3 fires exactly 3, then the rule ends', () {
      final rule = mkRule(policy: 'auto', start: '2026-09-05', maxCount: 3);
      final res = runPass(mkDoc([rule]), [], [], DateTime(2026, 11, 7));
      expect(res.manualMaps.length, 3);
      expect(theRule(res)['firedCount'], 3);
      expect(theRule(res)['status'], 'ended');
    });

    test('T-R15b: daily maxCount=30 fires exactly 30, then ends', () {
      final rule = mkRule(
        policy: 'auto',
        start: '2026-10-09',
        maxCount: 30,
        interval: {'type': 'daily', 'every': 1},
      );
      final res = runPass(mkDoc([rule]), [], [], DateTime(2026, 11, 7));
      expect(res.manualMaps.length, 30);
      expect(theRule(res)['firedCount'], 30);
      expect(theRule(res)['status'], 'ended');
    });

    test('T-R19: user-deleted generated entry — stays posted, no re-post', () {
      final first = runPass(mkDoc([mkRule()]), [], [], DateTime(2026, 11, 9));
      expect(first.manualMaps.length, 1);
      final second = runPass(
        first.store,
        [], // the user deleted the entry
        [],
        DateTime(2026, 11, 12),
      );
      expect(occs(second).single['state'], 'posted');
      expect(second.manualMaps, isEmpty);
    });
  });

  group('late-match sweep (spec §3.3 step 4)', () {
    (Map<String, dynamic>, List<Map<String, dynamic>>) postedFixture({
      bool edited = false,
    }) {
      final entry = manualToJson(
        amount: 10000,
        label: 'Rent',
        at: DateTime(2026, 11, 5, 12),
        direction: TxnDirection.debit,
        bucket: Bucket.needs,
        mode: 'UPI',
        origin: 'recurring',
        recurringId: 'rec_a_1',
        occurrenceDate: '2026-11-05',
        postedAtMs: DateTime(2026, 11, 9).millisecondsSinceEpoch,
      );
      if (edited) entry['editedByUser'] = true;
      final rule = mkRule();
      rule['lastCreatedDate'] = '2026-11-05';
      rule['firedCount'] = 1;
      rule['occurrences'] = [
        {
          'date': '2026-11-05',
          'amountPaise': 1000000,
          'state': 'posted',
          'entryId': entryId(manualTxnFromJson(entry)),
        },
      ];
      return (mkDoc([rule]), [entry]);
    }

    test('T-R8: strong late match removes the generated entry', () {
      final (doc, maps) = postedFixture();
      final res = runPass(doc, maps, [
        cap(amount: 10000, party: 'landlord', at: DateTime(2026, 11, 5, 10)),
      ], DateTime(2026, 11, 7));
      expect(res.manualMaps, isEmpty); // counted once — via the capture
      expect(occs(res).single['state'], 'matched');
      expect(occs(res).single['captureKey'], isNotNull);
      expect(theRule(res)['firedCount'], 1); // unchanged by the sweep
    });

    test('T-R9: edited entry is kept and flagged; resolution is terminal', () {
      final (doc, maps) = postedFixture(edited: true);
      final res = runPass(doc, maps, [
        cap(amount: 10000, party: 'landlord', at: DateTime(2026, 11, 5, 10)),
      ], DateTime(2026, 11, 7));
      expect(res.manualMaps.length, 1); // entry KEPT
      expect(occs(res).single['state'], 'flagged');
      expect(occs(res).single['flagReason'], 'possibleDuplicate');
      expect(
        resolveFlaggedDuplicate(
          res.store,
          res.manualMaps,
          'rec_a_1',
          '2026-11-05',
          removeGenerated: true,
        ),
        isTrue,
      );
      expect(res.manualMaps, isEmpty);
      final again = runPass(res.store, res.manualMaps, [
        cap(amount: 10000, party: 'landlord', at: DateTime(2026, 11, 5, 10)),
      ], DateTime(2026, 11, 8));
      expect(occs(again).single['state'], 'resolved'); // never re-flagged
    });

    test('T-R9b: a weak match NEVER auto-deletes — it flags', () {
      final (doc, maps) = postedFixture();
      final res = runPass(doc, maps, [
        cap(
          amount: 10000,
          party: 'LANDLORD RENT PAYMENT', // contains, not exact → weak
          at: DateTime(2026, 11, 5, 10),
        ),
      ], DateTime(2026, 11, 7));
      expect(res.manualMaps.length, 1);
      expect(occs(res).single['state'], 'flagged');
      // "Keep both" leaves everything in place.
      expect(
        resolveFlaggedDuplicate(
          res.store,
          res.manualMaps,
          'rec_a_1',
          '2026-11-05',
          removeGenerated: false,
        ),
        isTrue,
      );
      expect(res.manualMaps.length, 1);
      expect(occs(res).single['state'], 'resolved');
    });

    test('T-R16: a posted occurrence 34 days old is still sweepable', () {
      final entry = manualToJson(
        amount: 10000,
        label: 'Rent',
        at: DateTime(2026, 10, 4, 12),
        direction: TxnDirection.debit,
        bucket: Bucket.needs,
        mode: 'UPI',
        origin: 'recurring',
        recurringId: 'rec_a_1',
        occurrenceDate: '2026-10-04',
      );
      final rule = mkRule(
        start: '2026-10-04',
        interval: {'type': 'monthly', 'every': 1, 'dayOfMonth': 4},
      );
      rule['lastCreatedDate'] = '2026-11-04';
      rule['firedCount'] = 1;
      rule['occurrences'] = [
        {
          'date': '2026-10-04',
          'amountPaise': 1000000,
          'state': 'posted',
          'entryId': entryId(manualTxnFromJson(entry)),
        },
        {'date': '2026-11-04', 'amountPaise': 1000000, 'state': 'posted'},
      ];
      final res = runPass(mkDoc([rule]), [entry], [
        cap(amount: 10000, party: 'landlord', at: DateTime(2026, 10, 4, 9)),
      ], DateTime(2026, 11, 7));
      final oct = occs(res).firstWhere((o) => o['date'] == '2026-10-04');
      expect(oct['state'], 'matched');
      expect(res.manualMaps, isEmpty);
    });

    test('T-R16b: pruning keeps pending/flagged forever, caps history', () {
      final rule = mkRule();
      rule['occurrences'] = [
        for (var i = 0; i < 70; i++)
          {
            'date': addDaysStr('2026-08-01', i),
            'amountPaise': 1000000,
            'state': 'posted',
          },
        {'date': '2020-01-01', 'amountPaise': 1000000, 'state': 'flagged'},
        {'date': '2020-01-02', 'amountPaise': 1000000, 'state': 'pending'},
      ];
      pruneOccurrences(rule, '2026-11-07');
      final kept = occurrencesOf(rule);
      expect(kept.any((o) => o['date'] == '2020-01-01'), isTrue);
      expect(kept.any((o) => o['date'] == '2020-01-02'), isTrue);
      expect(kept.length, lessThanOrEqualTo(62));
    });
  });

  group('budget alerts (spec §4)', () {
    final now = DateTime(2026, 11, 7, 10);
    const monthKey = '2026-11';

    BudgetAlertOutcome eval({
      Map<String, dynamic>? state,
      Map<String, int> caps = const {'Groceries': 600000},
      int? overallCap,
      Map<String, int> spent = const {},
      int overall = 0,
      bool alertsOn = true,
      bool foreground = false,
    }) => evaluateBudgetAlerts(
      state: state ?? <String, dynamic>{},
      monthKey: monthKey,
      capsPaise: caps,
      overallCapPaise: overallCap,
      spentByCategory: spent,
      overallSpent: overall,
      now: now,
      alertsOn: alertsOn,
      isForeground: foreground,
    );

    test('T-B1: 80% fires exactly once; 79% does not fire', () {
      expect(eval(spent: {'Groceries': 474000}).newCrossings, isEmpty);
      final fired = eval(spent: {'Groceries': 480000});
      expect(fired.newCrossings.single.threshold, 80);
      expect(fired.wantsNotification, isTrue);
      final again = eval(state: fired.state, spent: {'Groceries': 490000});
      expect(again.newCrossings, isEmpty); // no re-fire
    });

    test('T-B2: 100% fires; one aggregated notification for both', () {
      final res = eval(spent: {'Groceries': 600000});
      expect(res.newCrossings.map((c) => c.threshold), [100, 80]);
      expect(res.notificationTitle, 'Budget alert');
      expect(res.notificationBody, contains('Groceries crossed 100%'));
      expect(res.notificationBody, contains('Groceries crossed 80%'));
    });

    test('T-B3: overall cap fires on total spend; savings excluded', () {
      final txns = [
        AlertTxn(
          amountPaise: 900000,
          isDebit: true,
          category: 'Investments',
          bucket: Bucket.savings,
          at: DateTime(2026, 11, 3),
        ),
        AlertTxn(
          amountPaise: 850000,
          isDebit: true,
          category: 'Uncategorized',
          bucket: Bucket.wants,
          at: DateTime(2026, 11, 3),
        ),
        AlertTxn(
          amountPaise: 500000,
          isDebit: false, // credits never net
          category: 'Salary',
          bucket: Bucket.needs,
          at: DateTime(2026, 11, 3),
        ),
      ];
      final overall = overallSpentPaise(
        txns,
        DateTime(2026, 11, 1),
        DateTime(2026, 12, 1),
      );
      expect(overall, 850000);
      final res = eval(
        caps: const {},
        overallCap: 1000000,
        overall: overall,
      );
      expect(res.newCrossings.single.alertKey, '__overall__');
      expect(res.newCrossings.single.threshold, 80);
    });

    test('T-B4: re-arm only on cap change, never on spend drop alone', () {
      final fired = eval(spent: {'Groceries': 500000});
      expect(firedThresholds(fired.state, monthKey, 'cat:Groceries'), {80});
      // Spend drops, same cap → stays fired.
      final dropped = eval(state: fired.state, spent: {'Groceries': 100000});
      expect(
        firedThresholds(dropped.state, monthKey, 'cat:Groceries'),
        {80},
      );
      // Cap raised so the crossing disappears → re-armed.
      final raised = eval(
        state: fired.state,
        caps: const {'Groceries': 1200000},
        spent: {'Groceries': 500000},
      );
      expect(firedThresholds(raised.state, monthKey, 'cat:Groceries'), isEmpty);
      // …and crossing the NEW cap's 80% fires again.
      final refired = eval(
        state: raised.state,
        caps: const {'Groceries': 1200000},
        spent: {'Groceries': 960000},
      );
      expect(refired.newCrossings.single.threshold, 80);
    });

    test('T-B5: third crossing in a day is suppressed, then bannered', () {
      final state = <String, dynamic>{
        '_meta': {
          'notifiedCountByDate': {'2026-11-07': 2},
        },
      };
      final res = eval(state: state, spent: {'Groceries': 480000});
      expect(res.wantsNotification, isFalse);
      expect(firedThresholds(res.state, monthKey, 'cat:Groceries'), {80});
      final lines = bannerLines(res.state, monthKey, now);
      expect(lines, contains('Groceries crossed 80%'));
    });

    test('T-B6: first-ever notification carries the honesty line', () {
      final first = eval(spent: {'Groceries': 480000});
      expect(
        first.notificationBody,
        contains('Alerts are checked when you open Kanakku'),
      );
      recordNotificationPosted(first.state, now);
      final meta = first.state['_meta'] as Map;
      expect((meta['notifiedCountByDate'] as Map)['2026-11-07'], 1);
      final second = eval(
        state: first.state,
        caps: const {'Groceries': 600000, 'Travel': 100000},
        spent: {'Groceries': 480000, 'Travel': 90000},
      );
      expect(second.wantsNotification, isTrue);
      expect(
        second.notificationBody,
        isNot(contains('Alerts are checked when you open Kanakku')),
      );
    });

    test('T-B7: alerts off — state records, nothing notifies or queues', () {
      final res = eval(spent: {'Groceries': 600000}, alertsOn: false);
      expect(res.newCrossings.length, 2); // recorded in state
      expect(firedThresholds(res.state, monthKey, 'cat:Groceries'), {80, 100});
      expect(res.wantsNotification, isFalse);
      final meta = res.state['_meta'];
      expect(meta == null || (meta as Map)['suppressedCrossings'] == null, isTrue);
    });

    test('T-B12: foreground evaluation — banner only, no notification', () {
      final res = eval(spent: {'Groceries': 480000}, foreground: true);
      expect(res.wantsNotification, isFalse);
      expect(firedThresholds(res.state, monthKey, 'cat:Groceries'), {80});
      expect(bannerLines(res.state, monthKey, now), isNotEmpty);
      dismissBanner(res.state, now);
      expect(bannerLines(res.state, monthKey, now), isEmpty);
    });

    test('T-B11: rename follows the category; delete starts clean', () {
      final fired = eval(spent: {'Groceries': 600000});
      renameCategoryAlertKey(fired.state, monthKey, 'Groceries', 'Food');
      expect(firedThresholds(fired.state, monthKey, 'cat:Food'), {80, 100});
      expect(firedThresholds(fired.state, monthKey, 'cat:Groceries'), isEmpty);
      deleteCategoryAlertKey(fired.state, monthKey, 'Food');
      expect(firedThresholds(fired.state, monthKey, 'cat:Food'), isEmpty);
    });

    test('integer percent: 599999/600000 is 99% — only 80 fires', () {
      final res = eval(spent: {'Groceries': 599999});
      expect(res.newCrossings.map((c) => c.threshold), [80]);
    });
  });

  group('migration & backup (spec §6)', () {
    test('T-X1: empty/garbage stores decode to safe defaults', () {
      expect(decodeRecurringStore('')['rules'], isEmpty);
      expect(decodeRecurringStore('not json')['nextRuleSeq'], 1);
      expect(decodeAlertState(''), isEmpty);
      final s = KanakkuSettings.fromJson({'profileName': 'Guna'});
      expect(s.overallMonthlyCapPaise, isNull);
      expect(s.budgetAlertsOn, isTrue);
      expect(s.biometricUnlock, isFalse);
    });

    test('T-B3b: a v1.0.4 backup (no recurring key) leaves rules untouched', () {
      final backup = jsonEncode({
        'app': 'kanakku',
        'formatVersion': 1,
        'createdAt': 1,
        'stores': {'manual': '[]', 'budgets': '{}'},
        'settings': <String, dynamic>{},
      });
      final parsed = parseBackup(backup);
      expect(parsed, isNotNull);
      expect(parsed!.stores.containsKey('recurring'), isFalse);
    });

    test('restore hold: rules held, past occurrences skipped, keys kept', () {
      final rule = mkRule();
      rule['occurrences'] = [
        {'date': '2026-10-05', 'amountPaise': 1000000, 'state': 'pending'},
        {
          'date': '2026-11-05',
          'amountPaise': 1000000,
          'state': 'matched',
          'captureKey': 'k1',
        },
        {'date': '2026-12-05', 'amountPaise': 1000000, 'state': 'pending'},
      ];
      final held = applyRestoreHold(mkDoc([rule]), '2026-11-07');
      final r = rulesOf(held).single;
      expect(r['restoredHold'], isTrue);
      final states = {for (final o in occurrencesOf(r)) o['date']: o['state']};
      expect(states['2026-10-05'], 'skipped');
      expect(states['2026-11-05'], 'skipped');
      expect(states['2026-12-05'], 'pending');
      expect(
        occurrencesOf(r).firstWhere((o) => o['date'] == '2026-11-05')['captureKey'],
        'k1', // kept, per spec §6.2
      );
      // A held rule never fires in an engine pass.
      final res = runPass(held, [], [], DateTime(2026, 11, 7));
      expect(res.manualMaps, isEmpty);
    });

    test('settings round-trip carries the v1.1 fields', () {
      const s = KanakkuSettings(
        overallMonthlyCapPaise: 2500000,
        budgetAlertsOn: false,
        biometricUnlock: true,
      );
      final back = KanakkuSettings.fromJson(s.toJson());
      expect(back.overallMonthlyCapPaise, 2500000);
      expect(back.budgetAlertsOn, isFalse);
      expect(back.biometricUnlock, isTrue);
    });
  });
}
