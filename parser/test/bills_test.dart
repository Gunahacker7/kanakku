import 'package:test/test.dart';
import 'package:kanakku_parser/kanakku_parser.dart';
import 'package:kanakku_parser/bills.dart';

void main() {
  group('card bill formats', () {
    test('HDFC statement with total, min and named due date', () {
      final b = CardBillParser.parse(
        'Your HDFC Bank Credit Card XX1234 statement is ready. '
        'Total Amt Due: Rs.12,450.00, Min Amt Due: Rs.650.00. '
        'Payment due date: 05-Nov-2026. Ignore if paid.',
        sender: 'VM-HDFCBK',
        receivedAt: DateTime(2026, 10, 20),
      );
      expect(b, isNotNull);
      expect(b!.totalDue, 12450.00);
      expect(b.minDue, 650.00);
      expect(b.cardLast4, '1234');
      expect(b.bankHint, 'HDFC Bank');
      expect(b.dueDate, DateTime(2026, 11, 5));
      expect(b.daysRemaining(DateTime(2026, 10, 28)), 8);
    });

    test('SBI Card "is" phrasing with pay-by named date', () {
      final b = CardBillParser.parse(
        'Dear Cardholder, your SBI Card ending 5678 total amount due is '
        'Rs.8,230.00 and minimum amount due is Rs.415.00. '
        'Please pay by 12 Nov 2026 to avoid late fee.',
        sender: 'VM-SBICRD',
        receivedAt: DateTime(2026, 10, 20),
      );
      expect(b, isNotNull);
      expect(b!.totalDue, 8230.00);
      expect(b.minDue, 415.00);
      expect(b.cardLast4, '5678');
      expect(b.bankHint, 'SBI');
      expect(b.dueDate, DateTime(2026, 11, 12));
    });

    test('ICICI short form with numeric dd/mm/yyyy date', () {
      final b = CardBillParser.parse(
        'ICICI Bank Credit Card XX9012: Total due Rs 3,999, Min due Rs 200, '
        'due by 28/10/2026.',
        sender: 'VM-ICICIB',
        receivedAt: DateTime(2026, 10, 15),
      );
      expect(b, isNotNull);
      expect(b!.totalDue, 3999.00);
      expect(b.minDue, 200.00);
      expect(b.cardLast4, '9012');
      expect(b.dueDate, DateTime(2026, 10, 28));
    });

    test('Axis "Rs X is due" phrasing with 2-digit year', () {
      final b = CardBillParser.parse(
        'Rs.5,600.00 is due on your Axis Bank Credit Card XX3456. '
        'Pay by 20-Nov-26.',
        sender: 'VM-AXISBK',
        receivedAt: DateTime(2026, 10, 25),
      );
      expect(b, isNotNull);
      expect(b!.totalDue, 5600.00);
      expect(b.minDue, isNull);
      expect(b.cardLast4, '3456');
      expect(b.dueDate, DateTime(2026, 11, 20));
    });

    test('due date without year uses the message year', () {
      final b = CardBillParser.parse(
        'Kotak Credit Card 9876: Total Amt Due Rs.2,100.00. Due by 05-Nov.',
        sender: 'VM-KOTAKB',
        receivedAt: DateTime(2026, 10, 25),
      );
      expect(b, isNotNull);
      expect(b!.dueDate, DateTime(2026, 11, 5));
    });

    test('bill without a stated due date still parses', () {
      final b = CardBillParser.parse(
        'Your Yes Bank Credit Card XX1234 Total Amt Due is Rs.9,999.00. '
        'Please pay at the earliest.',
        sender: 'VM-YESBNK',
        receivedAt: DateTime(2026, 10, 25),
      );
      expect(b, isNotNull);
      expect(b!.totalDue, 9999.00);
      expect(b.dueDate, isNull);
      expect(b.daysRemaining(), isNull);
    });
  });

  group('statement is not a transaction', () {
    test('"ignore if paid" statement does not become a fake expense', () {
      const body =
          'Your HDFC Bank Credit Card XX4321 statement is ready. '
          'Total Amt Due: Rs.12,450.00, Min Amt Due: Rs.650.00. '
          'Payment due date: 05-Nov-2026. Ignore if paid.';
      // The transaction parser must reject it (the word "paid" is not a
      // spend) while the bill parser extracts the due.
      expect(KanakkuParser.parse(body, sender: 'VM-HDFCBK'), isNull);
      final b = CardBillParser.parse(body, sender: 'VM-HDFCBK');
      expect(b, isNotNull);
      expect(b!.totalDue, 12450.00);
    });
  });

  group('bill rejections', () {
    test('ordinary spend alert is not a bill', () {
      final b = CardBillParser.parse(
        'INR 2,499.00 spent on your Kotak Card 9876 at FLIPKART on 11-10-2026.',
        sender: 'VM-KOTAKB',
      );
      expect(b, isNull);
    });

    test('OTP mentioning an amount due is rejected', () {
      final b = CardBillParser.parse(
        'Your OTP is 112233 for payment of Total Amt Due Rs.5,000.00. '
        'Do not share it.',
        sender: 'VM-HDFCBK',
      );
      expect(b, isNull);
    });

    test('statement-ready alert without amounts is not a bill', () {
      final b = CardBillParser.parse(
        'Your A/c XX1234 statement is ready. Login to view.',
        sender: 'VM-YESBNK',
      );
      expect(b, isNull);
    });
  });

  group('bill dedupe + overdue', () {
    test('same bill from SMS and notification shares a key', () {
      const body =
          'HDFC Bank Credit Card XX1234. Total Amt Due: Rs.12,450.00. '
          'Payment due date: 05-Nov-2026.';
      final a = CardBillParser.parse(body,
          source: TxnSource.sms, receivedAt: DateTime(2026, 10, 20));
      final b = CardBillParser.parse(body,
          source: TxnSource.notification, receivedAt: DateTime(2026, 10, 21));
      expect(a!.dedupeKey, b!.dedupeKey);
    });

    test('daysRemaining goes negative once overdue', () {
      final b = CardBillParser.parse(
        'ICICI Bank Credit Card XX9012: Total due Rs 3,999, due by 28/10/2026.',
        sender: 'VM-ICICIB',
        receivedAt: DateTime(2026, 10, 15),
      );
      expect(b!.daysRemaining(DateTime(2026, 10, 31)), -3);
    });
  });
}
