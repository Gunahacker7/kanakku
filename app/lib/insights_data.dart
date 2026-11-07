/// Insights computations (v0.6): weekly bucketing of the current
/// month's spend and per-category shares for the reference-style
/// "Spending overview" / "Where it goes" cards. Pure functions over a
/// minimal txn shape so they are unit-testable without the parser.
library;

import 'package:kanakku_parser/categorize.dart';

class InsightTxn {
  final DateTime at;
  final double amount;
  final bool isDebit;
  final String category; // raw parser category ('Utilities', 'Travel', …)
  final Bucket bucket;
  const InsightTxn({
    required this.at,
    required this.amount,
    required this.isDebit,
    required this.category,
    required this.bucket,
  });
}

/// Display grouping used by the reference layout: our raw categories
/// fold into the screenshot's broader buckets.
String displayCategory(String raw) => switch (raw) {
  'Utilities' || 'Recharge & Bills' => 'Bills & utilities',
  'Travel' || 'Fuel' => 'Transport',
  'Food Delivery' => 'Food & dining',
  'Uncategorized' => 'Other',
  _ => raw,
};

/// Which week bucket a day-of-month falls in: 1–7 → 0, 8–14 → 1,
/// 15–21 → 2, 22–28 → 3, 29–end → 4.
int weekIndex(int day) => day <= 28 ? (day - 1) ~/ 7 : 4;

/// Debit totals for [month] split into the 5 week buckets.
/// Credits and other months are ignored.
List<double> weeklyTotals(List<InsightTxn> txns, DateTime month) {
  final out = List<double>.filled(5, 0);
  for (final t in txns) {
    if (!t.isDebit) continue;
    if (t.at.year != month.year || t.at.month != month.month) continue;
    out[weekIndex(t.at.day)] += t.amount;
  }
  return out;
}

class CategoryTotal {
  final String name; // display category
  final double amount;
  final double share; // 0..1 of total expenses
  final int percent; // share × 100, rounded
  const CategoryTotal({
    required this.name,
    required this.amount,
    required this.share,
    required this.percent,
  });
}

/// Per-category debit totals for [month], grouped by display
/// category, sorted by amount descending. Empty when no spend.
List<CategoryTotal> categoryTotals(List<InsightTxn> txns, DateTime month) {
  final byCat = <String, double>{};
  var total = 0.0;
  for (final t in txns) {
    if (!t.isDebit) continue;
    if (t.at.year != month.year || t.at.month != month.month) continue;
    final name = displayCategory(t.category);
    byCat[name] = (byCat[name] ?? 0) + t.amount;
    total += t.amount;
  }
  if (total <= 0) return const [];
  final out = [
    for (final e in byCat.entries)
      CategoryTotal(
        name: e.key,
        amount: e.value,
        share: e.value / total,
        percent: (e.value / total * 100).round(),
      ),
  ]..sort((a, b) => b.amount.compareTo(a.amount));
  return out;
}

/// Debit totals within [start, end) split into 5 consecutive
/// 7-day buckets from [start] (the 5th bucket runs to [end]).
/// Used when a custom month-start day shifts the Insights chart
/// window away from the calendar month (v1.0).
List<double> weeklyTotalsIn(
  List<InsightTxn> txns,
  DateTime start,
  DateTime end,
) {
  final out = List<double>.filled(5, 0);
  for (final t in txns) {
    if (!t.isDebit) continue;
    if (t.at.isBefore(start) || !t.at.isBefore(end)) continue;
    final days = t.at.difference(start).inDays;
    final idx = days ~/ 7 > 4 ? 4 : days ~/ 7;
    out[idx] += t.amount;
  }
  return out;
}

/// Total debits in [month].
double monthSpend(List<InsightTxn> txns, DateTime month) {
  var total = 0.0;
  for (final t in txns) {
    if (!t.isDebit) continue;
    if (t.at.year != month.year || t.at.month != month.month) continue;
    total += t.amount;
  }
  return total;
}

/// Per-category debit totals within an arbitrary range
/// [start, end) — used when the period selector is not "this month"
/// (v0.7). Same grouping/sorting contract as [categoryTotals].
List<CategoryTotal> categoryTotalsIn(
  List<InsightTxn> txns,
  DateTime start,
  DateTime end,
) {
  final byCat = <String, double>{};
  var total = 0.0;
  for (final t in txns) {
    if (!t.isDebit) continue;
    if (t.at.isBefore(start) || !t.at.isBefore(end)) continue;
    final name = displayCategory(t.category);
    byCat[name] = (byCat[name] ?? 0) + t.amount;
    total += t.amount;
  }
  if (total <= 0) return const [];
  final out = [
    for (final e in byCat.entries)
      CategoryTotal(
        name: e.key,
        amount: e.value,
        share: e.value / total,
        percent: (e.value / total * 100).round(),
      ),
  ]..sort((a, b) => b.amount.compareTo(a.amount));
  return out;
}

/// Total debits within [start, end).
double spendIn(List<InsightTxn> txns, DateTime start, DateTime end) {
  var total = 0.0;
  for (final t in txns) {
    if (!t.isDebit) continue;
    if (t.at.isBefore(start) || !t.at.isBefore(end)) continue;
    total += t.amount;
  }
  return total;
}
