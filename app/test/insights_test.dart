import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/insights_data.dart';
import 'package:kanakku/theme.dart';
import 'package:kanakku_parser/categorize.dart';

InsightTxn _t(
  int day,
  double amount, {
  String cat = 'Groceries',
  bool debit = true,
  int month = 10,
  Bucket bucket = Bucket.needs,
}) => InsightTxn(
  at: DateTime(2026, month, day),
  amount: amount,
  isDebit: debit,
  category: cat,
  bucket: bucket,
);

void main() {
  final oct = DateTime(2026, 10, 1);

  group('weeklyTotals', () {
    test('buckets by day-of-month ranges', () {
      final w = weeklyTotals([
        _t(1, 100), _t(7, 50), // Wk 1
        _t(8, 200), _t(14, 10), // Wk 2
        _t(15, 300), _t(21, 20), // Wk 3
        _t(22, 400), _t(28, 30), // Wk 4
        _t(29, 500), _t(31, 40), // Wk 5
      ], oct);
      expect(w, [150.0, 210.0, 320.0, 430.0, 540.0]);
    });

    test('ignores credits and other months', () {
      final w = weeklyTotals([
        _t(5, 100),
        _t(5, 999, debit: false),
        _t(5, 888, month: 9),
      ], oct);
      expect(w, [100.0, 0.0, 0.0, 0.0, 0.0]);
    });

    test('weekIndex boundaries', () {
      expect(weekIndex(1), 0);
      expect(weekIndex(7), 0);
      expect(weekIndex(8), 1);
      expect(weekIndex(14), 1);
      expect(weekIndex(15), 2);
      expect(weekIndex(21), 2);
      expect(weekIndex(22), 3);
      expect(weekIndex(28), 3);
      expect(weekIndex(29), 4);
      expect(weekIndex(31), 4);
    });
  });

  group('categoryTotals', () {
    test('groups raw categories into display buckets, sorted desc', () {
      final cats = categoryTotals([
        _t(3, 600, cat: 'Utilities'),
        _t(4, 400, cat: 'Recharge & Bills'), // → Bills & utilities 1000
        _t(5, 300, cat: 'Travel'),
        _t(6, 200, cat: 'Fuel'), // → Transport 500
        _t(7, 250, cat: 'Food Delivery'), // → Food & dining 250
        _t(8, 250, cat: 'Groceries'),
      ], oct);
      expect(cats.map((c) => c.name).toList(), [
        'Bills & utilities',
        'Transport',
        'Food & dining',
        'Groceries',
      ]);
      expect(cats[0].amount, 1000);
      expect(cats[1].amount, 500);
    });

    test('percent is the rounded share of total expenses', () {
      final cats = categoryTotals([
        _t(3, 333, cat: 'Groceries'),
        _t(4, 667, cat: 'Shopping'),
      ], oct);
      expect(cats.first.percent, 67); // Shopping 667/1000
      expect(cats.last.percent, 33); // Groceries 333/1000
      expect(cats.last.share, closeTo(0.333, 0.0001));
    });

    test('empty when no spend this month', () {
      expect(categoryTotals([_t(3, 100, month: 9)], oct), isEmpty);
      expect(categoryTotals(const [], oct), isEmpty);
    });
  });

  group('inrCompact', () {
    test('below ₹1,000 keeps the full format', () {
      expect(KanakkuTheme.inrCompact(500), '₹500');
      expect(KanakkuTheme.inrCompact(999), '₹999');
      expect(KanakkuTheme.inrCompact(0), '₹0');
    });

    test('thousands become k with one trimmed decimal', () {
      expect(KanakkuTheme.inrCompact(7800), '₹7.8k');
      expect(KanakkuTheme.inrCompact(7000), '₹7k');
      expect(KanakkuTheme.inrCompact(12500), '₹12.5k');
      expect(KanakkuTheme.inrCompact(1000), '₹1k');
    });

    test('lakhs become L', () {
      expect(KanakkuTheme.inrCompact(120000), '₹1.2L');
      expect(KanakkuTheme.inrCompact(100000), '₹1L');
      expect(KanakkuTheme.inrCompact(250000), '₹2.5L');
    });

    test('negatives keep the sign', () {
      expect(KanakkuTheme.inrCompact(-7800), '-₹7.8k');
    });
  });
}
