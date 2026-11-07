import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/csv_export.dart';
import 'package:kanakku/pdf_export.dart';
import 'package:kanakku/pin.dart';
import 'package:kanakku/splits.dart';
import 'package:kanakku/summary.dart';

CsvTxnRow _row(String label, double amount, {String dir = 'debit'}) =>
    CsvTxnRow(
      date: DateTime(2026, 10, 12),
      label: label,
      category: 'Shopping',
      bucket: 'wants',
      direction: dir,
      amount: amount,
      bank: 'HDFC Bank',
      accountLast4: '4321',
      source: 'sms',
    );

void main() {
  group('equalSplit', () {
    test('splits evenly and sums exactly to the paise', () {
      final s = equalSplit(100, 3);
      expect(s.length, 3);
      expect(s.fold(0.0, (a, b) => a + b), closeTo(100, 0.001));
      expect(s, [33.34, 33.33, 33.33]); // leftover paise goes first
    });

    test('single person gets everything; zero people gets nothing', () {
      expect(equalSplit(250.50, 1), [250.50]);
      expect(equalSplit(250.50, 0), isEmpty);
    });
  });

  group('netBalances', () {
    SplitRecord split(
      String payer,
      Map<String, double> shares, {
      Set<String> settled = const {},
    }) => SplitRecord(
      id: 's',
      entryId: 'e',
      label: 'Dinner',
      total: shares.values.fold(0.0, (a, b) => a + b),
      payer: payer,
      shares: [
        for (final e in shares.entries)
          SplitShare(
            name: e.key,
            amount: e.value,
            settled: settled.contains(e.key),
          ),
      ],
      ts: 0,
    );

    test('others owe you when you paid', () {
      final b = netBalances([
        split(kYou, {kYou: 300, 'Asha': 300, 'Bala': 300}),
      ]);
      expect(b, {'Asha': 300.0, 'Bala': 300.0});
    });

    test('you owe the payer when someone else paid', () {
      final b = netBalances([
        split('Asha', {'Asha': 200, kYou: 200}),
      ]);
      expect(b, {'Asha': -200.0});
    });

    test('settled shares and third-party debts are ignored', () {
      final b = netBalances([
        split(kYou, {kYou: 100, 'Asha': 100, 'Bala': 100}, settled: {'Asha'}),
        split('Asha', {'Asha': 50, 'Bala': 50}), // Bala owes Asha, not us
      ]);
      expect(b, {'Bala': 100.0});
    });
  });

  group('splits JSON', () {
    test('round-trips through encode/decode', () {
      final orig = SplitRecord(
        id: 'split-1',
        entryId: 'txn-9',
        label: 'AMAZON INDIA',
        total: 1200,
        payer: kYou,
        shares: const [
          SplitShare(name: kYou, amount: 600, settled: true),
          SplitShare(name: 'Asha', amount: 600),
        ],
        ts: 12345,
      );
      final back = decodeSplits(encodeSplits([orig]));
      expect(back.length, 1);
      expect(back.single.label, 'AMAZON INDIA');
      expect(back.single.shares[1].name, 'Asha');
      expect(back.single.shares[0].settled, isTrue);
    });

    test('garbage JSON decodes to empty', () {
      expect(decodeSplits('not json'), isEmpty);
      expect(decodeSplits('[]'), isEmpty);
    });
  });

  group('PDF export', () {
    test('builds a valid single-page PDF with the row text', () {
      final bytes = buildTransactionsPdf([
        _row('AMAZON INDIA', 1200),
        _row('SWIGGY', 499),
      ], generatedAt: DateTime(2026, 10, 29));
      final text = latin1.decode(bytes);
      expect(text.startsWith('%PDF-1.4'), isTrue);
      expect(text.contains('%%EOF'), isTrue);
      expect(text.contains('AMAZON INDIA'), isTrue);
      expect(text.contains('/Count 1'), isTrue);
      expect(pdfPageCount(2), 1);
    });

    test('paginates long lists', () {
      final rows = [for (var i = 0; i < 100; i++) _row('MERCHANT $i', 100)];
      final bytes = buildTransactionsPdf(
        rows,
        generatedAt: DateTime(2026, 10, 29),
      );
      final text = latin1.decode(bytes);
      expect(pdfPageCount(100), 3);
      expect(text.contains('/Count 3'), isTrue);
      expect(text.contains('MERCHANT 99'), isTrue);
    });

    test('escapes parentheses in merchant names', () {
      final bytes = buildTransactionsPdf([
        _row('SHOP (INDIA)', 10),
      ], generatedAt: DateTime(2026));
      final text = latin1.decode(bytes);
      expect(text.contains(r'SHOP \(INDIA\)'), isTrue);
    });
  });

  group('daily summary', () {
    test('computes today, top category and month', () {
      final now = DateTime(2026, 10, 29, 12);
      final s = computeSummary([
        SummaryTxn(
          at: DateTime(2026, 10, 29, 9),
          amount: 500,
          isDebit: true,
          category: 'Groceries',
        ),
        SummaryTxn(
          at: DateTime(2026, 10, 29, 10),
          amount: 300,
          isDebit: true,
          category: 'Groceries',
        ),
        SummaryTxn(
          at: DateTime(2026, 10, 29, 11),
          amount: 200,
          isDebit: true,
          category: 'Travel',
        ),
        SummaryTxn(
          at: DateTime(2026, 10, 29, 11),
          amount: 9000,
          isDebit: false,
          category: 'Salary',
        ),
        SummaryTxn(
          at: DateTime(2026, 10, 15),
          amount: 1000,
          isDebit: true,
          category: 'Rent',
        ),
        SummaryTxn(
          at: DateTime(2026, 9, 29),
          amount: 700,
          isDebit: true,
          category: 'Old month',
        ),
      ], now);
      expect(s.todaySpend, 1000);
      expect(s.todayCount, 3);
      expect(s.topCategory, 'Groceries');
      expect(s.monthSpend, 2000);
      expect(s.line, 'Today ₹1,000 · Month ₹2,000');
    });
  });

  group('PIN helpers', () {
    test('format accepts 4-6 digits only', () {
      expect(isValidPinFormat('1234'), isTrue);
      expect(isValidPinFormat('123456'), isTrue);
      expect(isValidPinFormat('123'), isFalse);
      expect(isValidPinFormat('1234567'), isFalse);
      expect(isValidPinFormat('12a4'), isFalse);
      expect(isValidPinFormat(''), isFalse);
    });

    test('lockout schedule: 30s doubling, capped at 15 min (v1.0.4)', () {
      // The reset-lock hatch is gone (audit F1); wrong PINs now buy
      // a growing lockout. This pure schedule mirrors
      // PinStore.lockoutSeconds in Kotlin.
      expect(pinMaxFailures, 5);
      expect(pinLockoutSeconds(0), 30);
      expect(pinLockoutSeconds(1), 60);
      expect(pinLockoutSeconds(2), 120);
      expect(pinLockoutSeconds(3), 240);
      expect(pinLockoutSeconds(4), 480);
      expect(pinLockoutSeconds(5), 900);
      expect(pinLockoutSeconds(6), 900);
      expect(pinLockoutSeconds(20), 900);
    });
  });
}
