import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/budgets.dart';

void main() {
  group('decodeBudgets', () {
    test('empty/garbage JSON → starter defaults', () {
      expect(decodeBudgets('{}'), defaultBudgetCaps);
      expect(decodeBudgets('not json'), defaultBudgetCaps);
      expect(decodeBudgets('[]'), defaultBudgetCaps);
    });

    test('persisted edits override defaults, defaults remain', () {
      final caps = decodeBudgets('{"Groceries": 9000, "Travel": 0}');
      expect(caps['Groceries'], 9000);
      expect(caps['Travel'], 0);
      expect(caps['Shopping'], defaultBudgetCaps['Shopping']);
    });

    test('encode/decode round-trip', () {
      final caps = {...defaultBudgetCaps, 'Health': 4321.0};
      expect(decodeBudgets(encodeBudgets(caps)), caps);
    });
  });

  group('budgetRows', () {
    test('spent, remaining, over-budget maths', () {
      final rows = budgetRows(
        const {'Groceries': 6000, 'Travel': 2000},
        const {'Groceries': 1500, 'Travel': 2600},
      );
      final g = rows.firstWhere((r) => r.category == 'Groceries');
      expect(g.remaining, 4500);
      expect(g.percentUsed, 25);
      expect(g.over, isFalse);
      final t = rows.firstWhere((r) => r.category == 'Travel');
      expect(t.over, isTrue);
      expect(t.fraction, greaterThan(1));
    });

    test('missing spend reads as zero', () {
      final rows = budgetRows(const {'Health': 2000}, const {});
      expect(rows.single.spent, 0);
      expect(rows.single.percentUsed, 0);
    });
  });
}
