/// Daily summary (Walnut parity, v0.5): "Today" card on Home plus the
/// one-line text handed to the native 21:00 daily notification.
library;

import 'theme.dart';

class SummaryTxn {
  final DateTime at;
  final double amount;
  final bool isDebit;
  final String category;
  const SummaryTxn({
    required this.at,
    required this.amount,
    required this.isDebit,
    required this.category,
  });
}

class DailySummary {
  final double todaySpend;
  final int todayCount;
  final String? topCategory; // today's biggest debit category
  final double monthSpend;
  const DailySummary({
    required this.todaySpend,
    required this.todayCount,
    required this.topCategory,
    required this.monthSpend,
  });

  /// The one-liner stored natively and posted at ~21:00.
  String get line =>
      'Today ${KanakkuTheme.inr(todaySpend)} · Month ${KanakkuTheme.inr(monthSpend)}';
}

/// [monthStart]/[monthEnd] (v1.0): when given, "month so far" is
/// measured inside that window (custom month-start day) instead of
/// the calendar month.
DailySummary computeSummary(
  List<SummaryTxn> txns,
  DateTime now, {
  DateTime? monthStart,
  DateTime? monthEnd,
}) {
  var todaySpend = 0.0, monthSpend = 0.0;
  var todayCount = 0;
  final byCategory = <String, double>{};
  for (final t in txns) {
    if (!t.isDebit) continue;
    final isToday =
        t.at.year == now.year && t.at.month == now.month && t.at.day == now.day;
    final isThisMonth = (monthStart != null && monthEnd != null)
        ? (!t.at.isBefore(monthStart) && t.at.isBefore(monthEnd))
        : (t.at.year == now.year && t.at.month == now.month);
    if (isToday) {
      todaySpend += t.amount;
      todayCount++;
      byCategory[t.category] = (byCategory[t.category] ?? 0) + t.amount;
    }
    if (isThisMonth) monthSpend += t.amount;
  }
  String? top;
  var best = 0.0;
  byCategory.forEach((k, v) {
    if (v > best) {
      best = v;
      top = k;
    }
  });
  return DailySummary(
    todaySpend: todaySpend,
    todayCount: todayCount,
    topCategory: top,
    monthSpend: monthSpend,
  );
}
