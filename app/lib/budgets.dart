/// Monthly category budgets (v0.7). Caps are keyed by the parser's
/// raw category names (see _categoryCaps history in main.dart) and
/// are user-editable from v0.7 on; edits persist natively as a JSON
/// map via the capture channel.
library;

import 'dart:convert';

import 'money.dart';

/// Starter monthly caps per category — the defaults the reference
/// design shipped with ("editable in a future update"; v0.7 is it).
const defaultBudgetCaps = <String, double>{
  'Groceries': 6000,
  'Food Delivery': 3000,
  'Travel': 2000,
  'Fuel': 3000,
  'Shopping': 5000,
  'Utilities': 3000,
  'Recharge & Bills': 1000,
  'Health': 2000,
  'Subscriptions': 500,
  'Entertainment': 1500,
};

/// Merges persisted user caps over the defaults. Unknown keys in the
/// JSON are kept (categories learned later can carry a cap too).
Map<String, double> decodeBudgets(String json) {
  final out = Map<String, double>.from(defaultBudgetCaps);
  try {
    final map = jsonDecode(json) as Map<String, dynamic>;
    map.forEach((k, v) {
      final n = (v as num?)?.toDouble();
      if (n != null && n >= 0) out[k] = n;
    });
  } catch (_) {}
  return out;
}

String encodeBudgets(Map<String, double> caps) => jsonEncode(caps);

/// v1.1 (spec §8): the same caps read as integer PAISE for the
/// budget-alert engine. The budgets store keeps speaking rupees
/// (doubles) — conversion happens only here, at the read boundary,
/// through money.dart.
Map<String, int> decodeBudgetCapsPaise(String json) => {
  for (final e in decodeBudgets(json).entries)
    e.key: paiseFromRupees(e.value),
};

/// One budget row ready for display: category, spent in the month,
/// cap, and derived figures.
class BudgetRow {
  final String category;
  final double spent;
  final double cap;
  const BudgetRow({
    required this.category,
    required this.spent,
    required this.cap,
  });
  double get remaining => cap - spent;
  double get fraction => cap <= 0 ? 0 : spent / cap;
  int get percentUsed => (fraction * 100).round();
  bool get over => spent > cap && cap > 0;
}

/// Builds rows for every category that has a cap, ordered by the
/// [caps] insertion order (defaults order = reference order), with
/// [spentByCategory] supplying current-month debit totals.
List<BudgetRow> budgetRows(
  Map<String, double> caps,
  Map<String, double> spentByCategory,
) => [
  for (final e in caps.entries)
    BudgetRow(
      category: e.key,
      spent: spentByCategory[e.key] ?? 0,
      cap: e.value,
    ),
];
