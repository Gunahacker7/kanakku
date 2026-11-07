import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/capture.dart';
import 'package:kanakku/csv_export.dart';
import 'package:kanakku_parser/kanakku_parser.dart';

ParsedTransaction _txn({
  required double amount,
  double? bal,
  String? last4,
  String? bank,
  required DateTime at,
}) => ParsedTransaction(
  amount: amount,
  direction: TxnDirection.debit,
  source: TxnSource.sms,
  receivedAt: at,
  rawBody: 'x',
  balanceAfter: bal,
  accountLast4: last4,
  bankHint: bank,
);

void main() {
  group('latestBalances', () {
    test('keeps the newest stated balance per account', () {
      final out = latestBalances([
        _txn(
          amount: 250,
          bal: 5432.10,
          last4: '1234',
          bank: 'Yes Bank',
          at: DateTime(2026, 10, 12),
        ),
        _txn(
          amount: 45000,
          bal: 52300.00,
          last4: '1234',
          bank: 'Yes Bank',
          at: DateTime(2026, 10, 1),
        ),
        _txn(
          amount: 1200,
          bal: 23450.00,
          last4: '4321',
          bank: 'HDFC Bank',
          at: DateTime(2026, 10, 11),
        ),
      ]);
      expect(out.length, 2);
      final yes = out.firstWhere((a) => a.last4 == '1234');
      expect(yes.balance, 5432.10); // Oct 12 beats Oct 1
      expect(out.first.last4, '1234'); // most recently updated first
    });

    test('skips transactions without balance or account', () {
      final out = latestBalances([
        _txn(amount: 100, at: DateTime(2026, 10, 12)),
        _txn(amount: 100, bal: 500, at: DateTime(2026, 10, 12)),
      ]);
      expect(out, isEmpty);
    });
  });

  group('transactionsCsv', () {
    test('header + rows with quoting', () {
      final csv = transactionsCsv([
        CsvTxnRow(
          date: DateTime(2026, 10, 12),
          label: 'AMAZON, INDIA',
          category: 'Shopping',
          bucket: 'wants',
          direction: 'debit',
          amount: 1200,
          bank: 'HDFC Bank',
          accountLast4: '4321',
          source: 'sms',
        ),
      ]);
      final lines = csv.trim().split('\n');
      expect(lines.length, 2);
      expect(lines[0], startsWith('Date,Label,Category'));
      expect(
        lines[1],
        '2026-10-12,"AMAZON, INDIA",Shopping,wants,debit,1200.00,HDFC Bank,4321,sms',
      );
    });

    test('empty list is header only', () {
      expect(transactionsCsv(const []).trim().split('\n').length, 1);
    });

    test('formula-leading cells are neutralised (v1.0.4, audit F9)', () {
      CsvTxnRow row(String label) => CsvTxnRow(
        date: DateTime(2026, 10, 12),
        label: label,
        category: 'Other',
        bucket: 'wants',
        direction: 'debit',
        amount: 10,
        bank: '',
        accountLast4: '',
        source: 'statement',
      );
      for (final evil in ['+2+2', '-2+2', '@SUM(1+1)', '\t=cmd', '\r=cmd']) {
        final line = transactionsCsv([row(evil)]).trim().split('\n')[1];
        final labelCell = line.split(',')[1];
        expect(
          labelCell.startsWith("'"),
          isTrue,
          reason: 'cell for <$evil> must be quote-prefixed, got $line',
        );
      }
      // A formula cell that also needs RFC quoting gets the prefix
      // inside the quotes, where the spreadsheet still honours it.
      final csv = transactionsCsv([
        row('=HYPERLINK("https://evil.example","open")'),
      ]);
      expect(csv.contains('"\'=HYPERLINK'), isTrue);
      // Ordinary labels are untouched.
      final ok = transactionsCsv([row('Coffee')]).trim().split('\n')[1];
      expect(ok.split(',')[1], 'Coffee');
    });
  });
}
