import 'package:test/test.dart';
import 'package:kanakku_parser/kanakku_parser.dart';
import 'package:kanakku_parser/categorize.dart';

void main() {
  group('bank SMS formats', () {
    test('Yes Bank debit with balance', () {
      final t = KanakkuParser.parse(
        'Rs.250.00 has been debited from your A/c XX1234 on 12-10-2026. '
        'Avl Bal: Rs.5,432.10. If not done by you, call 18001200.',
        sender: 'VM-YESBNK',
      );
      expect(t, isNotNull);
      expect(t!.amount, 250.00);
      expect(t.direction, TxnDirection.debit);
      expect(t.accountLast4, '1234');
      expect(t.balanceAfter, 5432.10);
      expect(t.bankHint, 'Yes Bank');
    });

    test('SBI UPI debit with VPA name', () {
      final t = KanakkuParser.parse(
        'Dear UPI user, A/c X5678 debited by Rs 499.00 on 12Oct26. '
        'Trf to VPA swiggy@okhdfc (SWIGGY). Ref No 512345678901.',
        sender: 'AD-SBIBNK',
      );
      expect(t, isNotNull);
      expect(t!.amount, 499.00);
      expect(t.direction, TxnDirection.debit);
      expect(t.accountLast4, '5678');
      expect(t.upiRef, '512345678901');
      expect(categorize(t.counterparty)?.category, 'Food Delivery');
    });

    test('HDFC debit at merchant', () {
      final t = KanakkuParser.parse(
        'Rs.1,200.00 debited from A/c **4321 on 12-10-26 at AMAZON INDIA. '
        'Avl bal Rs.23,450.00.',
        sender: 'VM-HDFCBK',
      );
      expect(t, isNotNull);
      expect(t!.amount, 1200.00);
      expect(t.counterparty, contains('AMAZON'));
      expect(categorize(t.counterparty)?.bucket, Bucket.wants);
    });

    test('ICICI Info-format UPI debit', () {
      final t = KanakkuParser.parse(
        'Dear Customer, your A/c XX9012 has been debited with INR 350.00 '
        'on 12-Oct-26. Info: UPI/UBER INDIA/123456. Avl Bal: INR 8,210.55.',
        sender: 'VM-ICICIB',
      );
      expect(t, isNotNull);
      expect(t!.amount, 350.00);
      expect(t.accountLast4, '9012');
      expect(t.counterparty, contains('UBER'));
    });

    test('Salary credit', () {
      final t = KanakkuParser.parse(
        'Rs.45,000.00 credited to your A/c XX1234 on 01-10-2026 by NEFT '
        'SALARY OCT. Avl Bal: Rs.52,300.00.',
        sender: 'VM-YESBNK',
      );
      expect(t, isNotNull);
      expect(t!.direction, TxnDirection.credit);
      expect(t.amount, 45000.00);
    });

    test('Card spend', () {
      final t = KanakkuParser.parse(
        'INR 2,499.00 spent on your Kotak Card 9876 at FLIPKART on 11-10-2026.',
        sender: 'VM-KOTAKB',
      );
      expect(t, isNotNull);
      expect(t!.direction, TxnDirection.debit);
      expect(t.accountLast4, '9876');
      expect(t.bankHint, 'Kotak');
    });
  });

  group('rejections', () {
    test('OTP is never a transaction', () {
      final t = KanakkuParser.parse(
        'Your OTP is 483920 for a transaction of Rs.1,000.00. Do not share it.',
        sender: 'VM-YESBNK',
      );
      expect(t, isNull);
    });

    test('Promo is rejected', () {
      final t = KanakkuParser.parse(
        'Congratulations! You have won a pre-approved loan of Rs.5,00,000. Apply now!',
        sender: 'VM-ADPROM',
      );
      expect(t, isNull);
    });

    test('Plain alert without amount is rejected', () {
      final t = KanakkuParser.parse(
        'Your A/c XX1234 statement is ready. Login to view.',
        sender: 'VM-YESBNK',
      );
      expect(t, isNull);
    });
  });

  group('dedupe', () {
    test('same txn from SMS and notification shares a key', () {
      const body =
          'Rs.499.00 debited from A/c XX5678. UPI Ref No 512345678901.';
      final a = KanakkuParser.parse(body, source: TxnSource.sms);
      final b = KanakkuParser.parse(body, source: TxnSource.notification);
      expect(a!.dedupeKey, b!.dedupeKey);
    });
  });
}
