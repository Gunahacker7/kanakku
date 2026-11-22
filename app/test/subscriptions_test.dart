import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/backup.dart';
import 'package:kanakku/calendar.dart';
import 'package:kanakku/recurring.dart' show dateStr;
import 'package:kanakku/subscriptions.dart';
import 'package:kanakku/subscriptions_ui.dart';

Map<String, dynamic> _sub({
  String name = 'YouTube Premium',
  String brandKey = 'youtube',
  int amountPaise = 38900,
  String cycle = 'monthly',
  int customDays = 30,
  String first = '2025-08-01',
  String category = 'Entertainment',
  String status = 'active',
  String? cancelledDate,
}) => normalizeSubscription({
  'id': 'sub_test_1',
  'name': name,
  'brandKey': brandKey,
  'amountPaise': amountPaise,
  'cycle': cycle,
  'customDays': customDays,
  'firstBillingDate': first,
  'category': category,
  'status': status,
  'cancelledDate': ?cancelledDate,
  'createdAt': 1,
  'updatedAt': 1,
});

Map<String, dynamic> _doc(List<Map<String, dynamic>> subs) => {
  'nextSubSeq': 99,
  'subscriptions': subs,
};

void main() {
  group('subscriptions store', () {
    test('defensive decode: garbage degrades to the empty document', () {
      final doc = decodeSubscriptionsStore('not json');
      expect(doc['nextSubSeq'], 1);
      expect(subscriptionsOf(doc), isEmpty);
      final doc2 = decodeSubscriptionsStore('');
      expect(subscriptionsOf(doc2), isEmpty);
    });

    test('normalize clamps bad values', () {
      final s = normalizeSubscription({
        'name': 'X',
        'amountPaise': -50,
        'cycle': 'weekly',
        'customDays': 0,
        'status': 'paused',
      });
      expect(s['amountPaise'], 0);
      expect(s['cycle'], 'monthly');
      expect(s['customDays'], 1);
      expect(s['status'], 'active');
      expect(s['category'], 'Other');
    });

    test('ids come from the persisted sequence, never the list', () {
      final doc = emptySubscriptionsStore();
      final a = newSubscriptionId(doc, 1000);
      final b = newSubscriptionId(doc, 1000);
      expect(a, isNot(b));
      expect(doc['nextSubSeq'], 3);
    });

    test('round-trip through encode/decode keeps fields', () {
      final doc = _doc([_sub()]);
      final back = decodeSubscriptionsStore(encodeSubscriptionsStore(doc));
      final s = subscriptionsOf(back).single;
      expect(s['name'], 'YouTube Premium');
      expect(s['amountPaise'], 38900);
      expect(s['firstBillingDate'], '2025-08-01');
    });
  });

  group('renewal engine — monthly', () {
    test('nominal day clamps to month end without drift', () {
      final s = _sub(first: '2026-01-31');
      expect(
        subBillingDates(s, '2026-01-01', '2026-04-30'),
        ['2026-01-31', '2026-02-28', '2026-03-31', '2026-04-30'],
      );
    });

    test('reference case: progress is Day 9 of 30 on Nov 9', () {
      final s = _sub(); // ₹389 monthly since Aug 1, 2025
      const today = '2026-11-09';
      expect(nextRenewalDate(s, today), '2026-12-01');
      final p = cycleProgress(s, today);
      expect(p.lastBilled, '2026-11-01');
      expect(p.next, '2026-12-01');
      expect(p.dayX, 9);
      expect(p.dayY, 30);
      expect(p.fraction, closeTo(8 / 30, 1e-9));
      expect(renewsLabel(s, today), 'Renews on Dec 1, 2026');
    });

    test('total spent = amount × elapsed cycles', () {
      final s = _sub();
      // Aug 2025 … Nov 2026 inclusive = 16 bills.
      expect(elapsedBillingDates(s, '2026-11-09').length, 16);
      expect(totalSpentPaise(s, '2026-11-09'), 16 * 38900);
    });

    test('a bill landing today already counts as billed', () {
      final s = _sub(first: '2026-11-09');
      expect(elapsedBillingDates(s, '2026-11-09'), ['2026-11-09']);
      expect(nextRenewalDate(s, '2026-11-09'), '2026-12-09');
    });

    test('before the first bill: starts label, virtual-cycle progress', () {
      final s = _sub(first: '2026-12-01');
      const today = '2026-11-09';
      expect(nextRenewalDate(s, today), '2026-12-01');
      expect(elapsedBillingDates(s, today), isEmpty);
      expect(totalSpentPaise(s, today), 0);
      expect(renewsLabel(s, today), 'Starts on Dec 1, 2026');
      final p = cycleProgress(s, today);
      expect(p.dayY, 30); // Nov 1 → Dec 1
      expect(p.dayX, 9);
    });

    test('renews tomorrow label', () {
      final s = _sub(first: '2026-10-10');
      expect(renewsLabel(s, '2026-11-09'), 'Renews tomorrow');
    });
  });

  group('renewal engine — yearly & custom', () {
    test('yearly leap-day anchor clamps and recovers', () {
      final s = _sub(cycle: 'yearly', first: '2024-02-29');
      expect(
        subBillingDates(s, '2024-01-01', '2028-12-31'),
        [
          '2024-02-29',
          '2025-02-28',
          '2026-02-28',
          '2027-02-28',
          '2028-02-29',
        ],
      );
      expect(nextRenewalDate(s, '2026-11-09'), '2027-02-28');
    });

    test('custom days step from the first billing date', () {
      final s = _sub(cycle: 'customDays', customDays: 30, first: '2026-01-01');
      expect(
        subBillingDates(s, '2026-01-01', '2026-04-15'),
        ['2026-01-01', '2026-01-31', '2026-03-02', '2026-04-01'],
      );
      expect(nextRenewalDate(s, '2026-01-15'), '2026-01-31');
      expect(cycleLabel(s), 'Every 30 days');
    });
  });

  group('cancelled subscriptions', () {
    test('no future renewals; spent stops at the cancel date', () {
      final s = _sub(
        first: '2026-01-05',
        status: 'cancelled',
        cancelledDate: '2026-06-15',
      );
      const today = '2026-11-09';
      expect(nextRenewalDate(s, today), isNull);
      expect(renewsLabel(s, today), 'Cancelled');
      // Jan 5 … Jun 5 = 6 bills landed before the Jun 15 cancel.
      expect(elapsedBillingDates(s, today).length, 6);
      expect(totalSpentPaise(s, today), 6 * 38900);
      expect(renewalsInRange(s, '2026-11-01', '2026-11-30', today), isEmpty);
      // …but its past renewals still show on the calendar.
      expect(
        renewalsInRange(s, '2026-03-01', '2026-03-31', today),
        ['2026-03-05'],
      );
    });
  });

  group('aggregates', () {
    test('upcoming renewals sort soonest first and honour the limit', () {
      final a = _sub(name: 'Later', first: '2026-11-20');
      final b = _sub(name: 'Sooner', first: '2026-11-12');
      final doc = _doc([a, b]);
      final up = upcomingRenewals(doc, '2026-11-09');
      expect(up.map((u) => u.sub['name']), ['Sooner', 'Later']);
      expect(upcomingRenewals(doc, '2026-11-09', limit: 1).length, 1);
    });

    test('dueWithin sums renewals in the window, actives only', () {
      final monthly = _sub(name: 'M', amountPaise: 10000, first: '2026-10-15');
      final yearly = _sub(
        name: 'Y',
        amountPaise: 50000,
        cycle: 'yearly',
        first: '2025-03-01',
      );
      final dead = _sub(
        name: 'D',
        amountPaise: 70000,
        first: '2026-10-11',
        status: 'cancelled',
        cancelledDate: '2026-11-01',
      );
      final due = dueWithin(_doc([monthly, yearly, dead]), '2026-11-09', 30);
      // Only the monthly's Nov 15 renewal falls in Nov 9 – Dec 9.
      expect(due.count, 1);
      expect(due.totalPaise, 10000);
    });

    test('renewalsInRange for an active sub covers future months', () {
      final s = _sub(first: '2026-01-01');
      expect(
        renewalsInRange(s, '2026-11-01', '2026-11-30', '2026-11-09'),
        ['2026-11-01'],
      );
      expect(
        renewalsInRange(s, '2027-02-01', '2027-02-28', '2026-11-09'),
        ['2027-02-01'],
      );
    });
  });

  group('reminders', () {
    test('pending only for tomorrow renewals, deduped by alert state', () {
      final s = _sub(first: '2026-11-10'); // first bill tomorrow
      final doc = _doc([s]);
      final state = <String, dynamic>{};
      final pending = pendingRenewalReminders(doc, state, '2026-11-09');
      expect(pending.length, 1);
      expect(pending.single.date, '2026-11-10');
      markRenewalReminded(state, 'sub_test_1', '2026-11-10');
      expect(pendingRenewalReminders(doc, state, '2026-11-09'), isEmpty);
      // A renewal two days out is not pending.
      final s2 = _sub(first: '2026-11-11');
      expect(
        pendingRenewalReminders(_doc([s2]), <String, dynamic>{}, '2026-11-09'),
        isEmpty,
      );
    });
  });

  group('capture matching (read-only)', () {
    test('matches by name, brand name and match fragments', () {
      final spotify = _sub(
        name: 'Spotify',
        brandKey: 'spotify',
        category: 'Music',
      );
      const payments = [
        SubPaymentView(name: 'SPOTIFY INDIA', amountPaise: 25000, date: '2026-11-01'),
        SubPaymentView(name: 'Swiggy', amountPaise: 49900, date: '2026-11-02'),
        SubPaymentView(name: 'Spotify', amountPaise: 25000, date: '2026-10-01'),
      ];
      final matched = matchedPayments(spotify, payments);
      expect(matched.length, 2);
      expect(matched.first.date, '2026-11-01'); // newest first
      final yt = _sub();
      expect(
        paymentMatchesSub(
          yt,
          const SubPaymentView(
            name: 'YOUTUBE PREMIUM',
            amountPaise: 38900,
            date: '2026-11-01',
          ),
        ),
        isTrue,
      );
      expect(
        paymentMatchesSub(
          yt,
          const SubPaymentView(
            name: 'NETFLIX',
            amountPaise: 64900,
            date: '2026-11-01',
          ),
        ),
        isFalse,
      );
    });
  });

  group('backup', () {
    test('subscriptions ride inside the v1 envelope additively', () {
      final backup = buildBackup(
        stores: const {
          'manual': '[]',
          'subscriptions': '{"nextSubSeq":2,"subscriptions":[]}',
        },
        settings: const {},
        createdAt: DateTime(2026, 11, 22),
      );
      final parsed = parseBackup(encodeBackup(backup));
      expect(parsed, isNotNull);
      expect(
        parsed!.stores['subscriptions'],
        '{"nextSubSeq":2,"subscriptions":[]}',
      );
      // A backup written by an OLDER app version (whose store-key
      // list predates subscriptions) has no such key at all — and
      // still parses, restoring as "leave subscriptions untouched".
      final oldJson = jsonEncode({
        'app': 'kanakku',
        'formatVersion': 1,
        'createdAt': 1,
        'stores': {'manual': '[]'},
        'settings': <String, dynamic>{},
      });
      final parsedOld = parseBackup(oldJson);
      expect(parsedOld, isNotNull);
      expect(parsedOld!.stores.containsKey('subscriptions'), isFalse);
    });
  });

  group('widgets', () {
    testWidgets('Subscriptions page lists subs with the summary card', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final doc = _doc([
        _sub(
          name: 'Spotify',
          brandKey: 'spotify',
          amountPaise: 25000,
          category: 'Music',
          first: '2026-10-27',
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionsPage(
            doc: doc,
            payments: const [],
            onApply: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Subscriptions'), findsOneWidget);
      expect(find.text('Spotify'), findsOneWidget);
      expect(find.text('Due in 30 days'), findsOneWidget);
      expect(find.text('Upcoming'), findsOneWidget);
    });

    testWidgets('Calendar page renders the real month grid + summary', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      final today = dateStr(now);
      await tester.pumpWidget(
        MaterialApp(
          home: CalendarPage(
            today: today,
            items: [
              CalendarItem(
                date: today,
                name: 'YouTube Premium',
                amountPaise: 38900,
                isRenewal: true,
                brandKey: 'youtube',
              ),
              CalendarItem(
                date: today,
                name: 'Groceries',
                amountPaise: 50000,
                category: 'Groceries',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Calendar'), findsOneWidget);
      expect(find.text('This month'), findsOneWidget);
      expect(find.text(subMonthNames[now.month - 1]), findsOneWidget);
      // Both of today's items count as payments in the summary.
      expect(find.textContaining('2 payments'), findsOneWidget);
      // The selected day lists both items, renewal pill included.
      expect(find.text('YouTube Premium'), findsOneWidget);
      expect(find.text('Groceries'), findsWidgets);
      expect(find.text('Renews'), findsOneWidget);
    });
  });
}
