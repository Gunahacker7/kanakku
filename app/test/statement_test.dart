import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/statement.dart';

void main() {
  group('csvCells', () {
    test('honours quoted fields with commas and escaped quotes', () {
      expect(csvCells('a,"1,200.00","say ""hi""",b'), [
        'a',
        '1,200.00',
        'say "hi"',
        'b',
      ]);
    });
  });

  group('parseStatementDate', () {
    test('Indian bank formats', () {
      expect(parseStatementDate('01/10/2026'), DateTime(2026, 10, 1));
      expect(parseStatementDate('01-10-2026'), DateTime(2026, 10, 1));
      expect(parseStatementDate('01/10/26'), DateTime(2026, 10, 1));
      expect(parseStatementDate('2026-10-01'), DateTime(2026, 10, 1));
      expect(parseStatementDate('12 Oct 2026'), DateTime(2026, 10, 12));
      expect(parseStatementDate('12-Oct-26'), DateTime(2026, 10, 12));
      expect(parseStatementDate('5 Jan 26'), DateTime(2026, 1, 5));
      expect(parseStatementDate('not a date'), isNull);
      expect(parseStatementDate(''), isNull);
    });
  });

  group('parseStatementCsv', () {
    test('HDFC style: preamble lines, Withdrawal/Deposit columns', () {
      const csv = '''
Account No,XX1234,,,,
Statement From 01/10/2026 To 31/10/2026,,,,,,
Date,Narration,Chq./Ref.No.,Value Dt,Withdrawal Amt.,Deposit Amt.,Closing Balance
01/10/2026,NEFT SALARY OCT,,01/10/2026,,45000.00,52300.00
02/10/2026,UPI/SWIGGY/512345,,02/10/2026,499.00,,51801.00
03/10/2026,AMAZON INDIA,,03/10/2026,"1,200.00",,50601.00
''';
      final r = parseStatementCsv(csv);
      expect(r.rows.length, 3);
      expect(r.rows[0].isDebit, isFalse);
      expect(r.rows[0].amount, 45000);
      expect(r.rows[0].balanceAfter, 52300);
      expect(r.rows[1].isDebit, isTrue);
      expect(r.rows[1].amount, 499);
      expect(r.rows[1].description, contains('SWIGGY'));
      expect(r.rows[2].amount, 1200);
      expect(r.rows[2].date, DateTime(2026, 10, 3));
    });

    test('ICICI style: Txn Date + Debit/Credit, dd-MMM-yyyy dates', () {
      const csv = '''
Txn Date,Description,Debit,Credit,Balance
12-Oct-2026,UPI/UBER INDIA/123,350.00,,8210.55
13-Oct-2026,SALARY CREDIT,,60000.00,68210.55
''';
      final r = parseStatementCsv(csv);
      expect(r.rows.length, 2);
      expect(r.rows[0].date, DateTime(2026, 10, 12));
      expect(r.rows[0].isDebit, isTrue);
      expect(r.rows[1].isDebit, isFalse);
      expect(r.rows[1].amount, 60000);
    });

    test('SBI style: two date columns, dd/mm/yy dates', () {
      const csv = '''
Txn Date,Value Date,Description,Ref No,Debit,Credit,Balance
01/10/26,01/10/26,ATM WDL SELF,,1000.00,,9000.00
02/10/26,02/10/26,UPI/ZEPT0,,250.00,,8750.00
''';
      final r = parseStatementCsv(csv);
      expect(r.rows.length, 2);
      expect(r.rows[0].date, DateTime(2026, 10, 1));
      expect(r.rows[0].amount, 1000);
      expect(r.rows.every((x) => x.isDebit), isTrue);
    });

    test('single Amount column with Dr/Cr indicator', () {
      const csv = '''
Date,Description,Amount,Dr/Cr
05/10/2026,AMAZON INDIA,2499.00,Dr
06/10/2026,REFUND AMAZON,500.00,Cr
''';
      final r = parseStatementCsv(csv);
      expect(r.rows.length, 2);
      expect(r.rows[0].isDebit, isTrue);
      expect(r.rows[1].isDebit, isFalse);
    });

    test('single Amount column with Dr/Cr suffix in the amount', () {
      const csv = '''
Date,Particulars,Amount
05/10/2026,POS STORE,"1,000.00 Dr"
06/10/2026,INTEREST,, 
07/10/2026,INTEREST CREDIT,120.50 Cr
''';
      final r = parseStatementCsv(csv);
      expect(r.rows.length, 2);
      expect(r.rows[0].amount, 1000);
      expect(r.rows[0].isDebit, isTrue);
      expect(r.rows[1].isDebit, isFalse);
    });

    test('no recognisable header → empty result', () {
      expect(parseStatementCsv('hello,world\n1,2').rows, isEmpty);
      expect(parseStatementCsv('').rows, isEmpty);
    });

    test('footer/total rows without dates are skipped', () {
      const csv = '''
Date,Narration,Withdrawal Amt.,Deposit Amt.,Closing Balance
01/10/2026,STORE,100.00,,900.00
,,,,Total,100.00,
''';
      final r = parseStatementCsv(csv);
      expect(r.rows.length, 1);
    });
  });

  group('dedupe', () {
    test('same day+amount+direction with overlapping descriptions match', () {
      final a = statementDedupeKey(
        DateTime(2026, 10, 2),
        499,
        true,
        'UPI/SWIGGY/512345678901',
      );
      final b = statementDedupeKey(DateTime(2026, 10, 2), 499, true, 'SWIGGY');
      expect(statementKeyMatches(a, b), isTrue);
      final c = statementDedupeKey(DateTime(2026, 10, 3), 499, true, 'SWIGGY');
      expect(statementKeyMatches(a, c), isFalse);
      final d = statementDedupeKey(DateTime(2026, 10, 2), 500, true, 'SWIGGY');
      expect(statementKeyMatches(a, d), isFalse);
    });
  });

  group('analyzeTransactions', () {
    final txns = [
      AnalysisTxn(
        at: DateTime(2026, 10, 1),
        description: 'SALARY',
        amount: 45000,
        isDebit: false,
        category: 'Salary',
      ),
      AnalysisTxn(
        at: DateTime(2026, 10, 2),
        description: 'SWIGGY',
        amount: 499,
        isDebit: true,
        category: 'Food Delivery',
      ),
      AnalysisTxn(
        at: DateTime(2026, 10, 3),
        description: 'AMAZON',
        amount: 1200,
        isDebit: true,
        category: 'Shopping',
      ),
      AnalysisTxn(
        at: DateTime(2026, 10, 3),
        description: 'SWIGGY AGAIN',
        amount: 300,
        isDebit: true,
        category: 'Food Delivery',
      ),
    ];

    test('totals, average daily spend, tops', () {
      final a = analyzeTransactions(txns);
      expect(a.totalIn, 45000);
      expect(a.totalOut, 1999);
      expect(a.net, 45000 - 1999);
      expect(a.count, 4);
      // Oct 1 → Oct 3 = 3 days
      expect(a.avgDailySpend, closeTo(1999 / 3, 0.01));
      expect(a.topCategories.first.name, 'Shopping');
      expect(a.topCategories.first.amount, 1200);
      expect(a.topCategories[1].name, 'Food & dining');
      expect(a.topCategories[1].amount, 799);
      expect(a.topMerchants.first.name, 'AMAZON');
      expect(a.topMerchants.first.amount, 1200);
      expect(a.largestExpenses.first.amount, 1200);
    });

    test('empty input is safe', () {
      final a = analyzeTransactions(const []);
      expect(a.count, 0);
      expect(a.totalOut, 0);
      expect(a.topCategories, isEmpty);
    });
  });

  group('categoryForDescription', () {
    test('runs through the merchant rules', () {
      expect(categoryForDescription('UPI/SWIGGY/123'), 'Food Delivery');
      expect(categoryForDescription('SOME UNKNOWN SHOP'), 'Uncategorized');
    });
  });
}
