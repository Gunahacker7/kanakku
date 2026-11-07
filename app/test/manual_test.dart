import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/main.dart' show periodRange, PeriodSel;
import 'package:kanakku/manual.dart';
import 'package:kanakku_parser/kanakku_parser.dart';
import 'package:kanakku_parser/categorize.dart';

void main() {
  group('manual store JSON (v0.8 income)', () {
    test('credit entry persists and reloads as credit', () {
      final at = DateTime(2026, 10, 29, 9, 30);
      final stored = manualToJson(
        amount: 50000,
        label: 'Salary',
        at: at,
        direction: TxnDirection.credit,
        note: 'October salary',
      );
      // On disk, income is marked; the note rides along.
      expect(stored['dir'], 'credit');
      expect(stored['note'], 'October salary');

      final decoded =
          jsonDecode(jsonEncode(stored)) as Map<String, dynamic>;
      final txn = manualTxnFromJson(decoded);
      expect(txn.direction, TxnDirection.credit);
      expect(txn.amount, 50000);
      expect(txn.counterparty, 'Salary');
      expect(txn.source, TxnSource.manual);
      expect(txn.receivedAt, at);
      expect(manualNoteFromJson(decoded), 'October salary');
    });

    test('expense entry writes no dir key and reloads as debit', () {
      final stored = manualToJson(
        amount: 250,
        label: 'Groceries',
        at: DateTime(2026, 10, 29),
        direction: TxnDirection.debit,
      );
      expect(stored.containsKey('dir'), isFalse);
      final txn = manualTxnFromJson(
        jsonDecode(jsonEncode(stored)) as Map<String, dynamic>,
      );
      expect(txn.direction, TxnDirection.debit);
    });

    // v1.0.1 regression (the v0.9.1 fix): the picked category, the
    // selected bucket and the note are three separate stored
    // fields — the note must not overwrite the category, and the
    // bucket must survive a save → reload round-trip instead of
    // being re-derived from the merchant table.
    test('expense entry persists category, selected bucket and note', () {
      final stored = manualToJson(
        amount: 250,
        label: 'Groceries',
        at: DateTime(2026, 10, 29),
        direction: TxnDirection.debit,
        note: 'Vegetables',
        bucket: Bucket.needs,
      );
      expect(stored.containsKey('dir'), isFalse);
      expect(stored['category'], 'Groceries');
      expect(stored['bucket'], 'needs');
      expect(stored['note'], 'Vegetables');
      final decoded = jsonDecode(jsonEncode(stored)) as Map<String, dynamic>;
      final txn = manualTxnFromJson(decoded);
      expect(txn.direction, TxnDirection.debit);
      expect(txn.counterparty, 'Groceries');
      expect(manualNoteFromJson(decoded), 'Vegetables');
      expect(manualBucketFromJson(decoded), Bucket.needs);
      // A store written before v1.0.1 has no bucket key: null, so
      // the entry keeps its parser-derived bucket.
      expect(manualBucketFromJson({'label': 'Groceries'}), isNull);
    });

    test('legacy JSON without dir reloads as debit (v0.1–v0.7 data)', () {
      final legacy = <String, dynamic>{
        'amount': 499.0,
        'label': 'Food Delivery',
        'ts': DateTime(2026, 10, 12).millisecondsSinceEpoch,
      };
      final txn = manualTxnFromJson(legacy);
      expect(txn.direction, TxnDirection.debit);
      expect(txn.amount, 499);
      expect(txn.counterparty, 'Food Delivery');
      expect(manualNoteFromJson(legacy), isNull);
    });

    test('income and expense of same amount + millisecond differ in id', () {
      final ts = DateTime(2026, 10, 29, 12).millisecondsSinceEpoch;
      final income = manualTxnFromJson({
        'amount': 1000.0,
        'label': 'Bonus',
        'ts': ts,
        'dir': 'credit',
      });
      final expense = manualTxnFromJson({
        'amount': 1000.0,
        'label': 'Bonus',
        'ts': ts,
      });
      expect(entryId(income), isNot(entryId(expense)));
      // …and the id is rebuilt identically on every load (stable).
      final incomeAgain = manualTxnFromJson({
        'amount': 1000.0,
        'label': 'Bonus',
        'ts': ts,
        'dir': 'credit',
      });
      expect(entryId(incomeAgain), entryId(income));
    });

    test('picked date (v0.9): stamp = picked date + current time-of-day', () {
      final now = DateTime(2026, 10, 29, 18, 45, 12, 300);
      final stamp = manualStamp(DateTime(2026, 9, 15), now);
      expect(stamp, DateTime(2026, 9, 15, 18, 45, 12, 300));
      // Picking today reproduces "now" exactly.
      expect(manualStamp(DateTime(2026, 10, 29), now), now);
    });

    test('picked date (v0.9): backdated entry round-trips with its date', () {
      final now = DateTime(2026, 10, 29, 9, 15);
      final stamp = manualStamp(DateTime(2026, 9, 2), now);
      final stored = manualToJson(
        amount: 1200,
        label: 'Groceries',
        at: stamp,
        direction: TxnDirection.debit,
      );
      final txn = manualTxnFromJson(
        jsonDecode(jsonEncode(stored)) as Map<String, dynamic>,
      );
      expect(txn.receivedAt, stamp);
      expect(txn.receivedAt.year, 2026);
      expect(txn.receivedAt.month, 9);
      expect(txn.receivedAt.day, 2);
    });

    test('picked date (v0.9): backdated entries land in the Last month '
        'period, not This month (period selector totals)', () {
      final now = DateTime(2026, 10, 29, 12);
      bool inPeriod(PeriodSel p, DateTime at) {
        final (start, end) = periodRange(p, now);
        return !at.isBefore(start) && at.isBefore(end);
      }

      final backExpense = manualStamp(DateTime(2026, 9, 15), now);
      expect(inPeriod(PeriodSel.lastMonth, backExpense), isTrue);
      expect(inPeriod(PeriodSel.thisMonth, backExpense), isFalse);

      // A backdated INCOME (Salary for last month) behaves the same.
      final backIncome = manualTxnFromJson(
        manualToJson(
          amount: 45000,
          label: 'Salary',
          at: manualStamp(DateTime(2026, 9, 1), now),
          direction: TxnDirection.credit,
        ),
      );
      expect(backIncome.direction, TxnDirection.credit);
      expect(inPeriod(PeriodSel.lastMonth, backIncome.receivedAt), isTrue);
      expect(inPeriod(PeriodSel.thisMonth, backIncome.receivedAt), isFalse);

      // And a future-dated entry is outside both past periods.
      final future = manualStamp(DateTime(2026, 11, 5), now);
      expect(inPeriod(PeriodSel.thisMonth, future), isFalse);
      expect(inPeriod(PeriodSel.allTime, future), isTrue);
    });

    test('picked date (v0.9): same amount + label on different dates '
        'get different ids', () {
      Map<String, dynamic> storedOn(DateTime picked) => manualToJson(
        amount: 500,
        label: 'Rent',
        at: manualStamp(picked, DateTime(2026, 10, 29, 8)),
        direction: TxnDirection.debit,
      );
      final a = manualTxnFromJson(storedOn(DateTime(2026, 10, 1)));
      final b = manualTxnFromJson(storedOn(DateTime(2026, 10, 2)));
      expect(entryId(a), isNot(entryId(b)));
    });

    test('income type list matches the requested options', () {
      expect(incomeTypes, [
        'Salary',
        'Bonus',
        'Freelance',
        'Interest',
        'Rental Income',
        'Refund / Cashback',
        'Gift',
        'Other',
      ]);
    });
  });
}
