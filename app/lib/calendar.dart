/// Calendar tab (v1.2, REDESIGN-SPEC screen mapping 3 /
/// reference 04): a month grid of payments — real transactions
/// plus subscription renewals — with a per-day list below.
///
/// The page is fed plain [CalendarItem] views built by the Shell
/// from its entries and the subscriptions document, so it holds no
/// store state of its own; month navigation and day selection are
/// purely local.
library;

import 'package:flutter/material.dart';

import 'money.dart';
import 'recurring.dart' show dateStr, parseDateStr;
import 'subscriptions.dart';
import 'theme.dart';

/// One calendar entry: a transaction or a subscription renewal.
class CalendarItem {
  final String date; // yyyy-mm-dd
  final String name;
  final int amountPaise;
  final bool isCredit;
  final bool isRenewal;

  /// Expense category for transactions (icon choice); null for
  /// renewals, which carry [brandKey] instead.
  final String? category;
  final String? brandKey;
  const CalendarItem({
    required this.date,
    required this.name,
    required this.amountPaise,
    this.isCredit = false,
    this.isRenewal = false,
    this.category,
    this.brandKey,
  });
}

IconData _categoryIcon(String? category) {
  final c = (category ?? '').toLowerCase();
  if (c.contains('food') || c.contains('grocer') || c.contains('dining')) {
    return Icons.restaurant_outlined;
  }
  if (c.contains('travel') || c.contains('transport') || c.contains('fuel')) {
    return Icons.directions_car_outlined;
  }
  if (c.contains('shop') || c.contains('amazon') || c.contains('retail')) {
    return Icons.shopping_bag_outlined;
  }
  if (c.contains('entertain') || c.contains('movie')) {
    return Icons.movie_outlined;
  }
  if (c.contains('health') || c.contains('medical') || c.contains('pharma')) {
    return Icons.local_hospital_outlined;
  }
  if (c.contains('utilit') || c.contains('bill') || c.contains('recharge')) {
    return Icons.receipt_long_outlined;
  }
  if (c.contains('subscri')) return Icons.subscriptions_outlined;
  if (c.contains('invest') || c.contains('saving')) {
    return Icons.trending_up;
  }
  if (c.contains('salary') || c.contains('income')) {
    return Icons.payments_outlined;
  }
  if (c.contains('rent') || c.contains('home')) return Icons.home_outlined;
  if (c.contains('educat') || c.contains('fee')) return Icons.school_outlined;
  return Icons.circle;
}

class CalendarPage extends StatefulWidget {
  final List<CalendarItem> items;

  /// yyyy-mm-dd "today" — the initial month + selection.
  final String today;
  const CalendarPage({super.key, required this.items, required this.today});
  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime _month = _monthOf(widget.today);
  late String _selected = widget.today;

  static DateTime _monthOf(String date) {
    final d = parseDateStr(date) ?? DateTime.now();
    return DateTime(d.year, d.month);
  }

  Map<String, List<CalendarItem>> get _byDate {
    final out = <String, List<CalendarItem>>{};
    for (final it in widget.items) {
      out.putIfAbsent(it.date, () => []).add(it);
    }
    return out;
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      // Keep the selection inside the visible month when possible.
      final sel = parseDateStr(_selected);
      if (sel == null || sel.year != _month.year || sel.month != _month.month) {
        _selected = dateStr(DateTime(_month.year, _month.month, 1));
      }
    });
  }

  void _goThisMonth() {
    setState(() {
      _month = _monthOf(widget.today);
      _selected = widget.today;
    });
  }

  Widget _dayCell(DateTime day, Map<String, List<CalendarItem>> byDate) {
    final ds = dateStr(day);
    final inMonth = day.month == _month.month;
    final items = byDate[ds] ?? const <CalendarItem>[];
    final selected = ds == _selected;
    final isToday = ds == widget.today;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        _selected = ds;
        if (!inMonth) _month = DateTime(day.year, day.month);
      }),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: selected ? KanakkuTheme.tealSoft : KanakkuTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: selected
              ? Border.all(color: KanakkuTheme.primary, width: 1.2)
              : null,
        ),
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: isToday || selected
                    ? FontWeight.w800
                    : FontWeight.w500,
                color: !inMonth
                    ? KanakkuTheme.inkSoft.withValues(alpha: 0.55)
                    : isToday
                    ? KanakkuTheme.primary
                    : KanakkuTheme.ink,
              ),
            ),
            SizedBox(
              height: 14,
              child: items.isEmpty
                  ? null
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final it in items.take(3))
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 0.5,
                            ),
                            child: Icon(
                              it.isRenewal
                                  ? brandFor(
                                      it.brandKey ?? 'custom',
                                      fallbackName: it.name,
                                    ).icon
                                  : _categoryIcon(it.category),
                              size: 11,
                              color: it.isRenewal
                                  ? brandFor(
                                      it.brandKey ?? 'custom',
                                      fallbackName: it.name,
                                    ).fg
                                  : it.isCredit
                                  ? KanakkuTheme.credit
                                  : KanakkuTheme.inkSoft,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final byDate = _byDate;
    final monthPrefix =
        '${_month.year.toString().padLeft(4, '0')}-'
        '${_month.month.toString().padLeft(2, '0')}';
    // Summary: payments = money out (debits + renewals).
    var payCount = 0, payTotal = 0;
    for (final it in widget.items) {
      if (!it.date.startsWith(monthPrefix)) continue;
      if (it.isCredit) continue;
      payCount++;
      payTotal += it.amountPaise;
    }
    // Grid: Monday-first weeks covering the month.
    final firstOfMonth = DateTime(_month.year, _month.month, 1);
    final startOffset = firstOfMonth.weekday - 1; // Mon = 0
    final gridStart = DateTime(
      _month.year,
      _month.month,
      1 - startOffset,
    );
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final weekCount = ((startOffset + daysInMonth + 6) ~/ 7);
    final selectedItems = byDate[_selected] ?? const <CalendarItem>[];
    final selDate = parseDateStr(_selected);
    const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const weekdayFull = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Calendar',
                  style: KanakkuTheme.sectionTitle(size: 26),
                ),
              ),
              OutlinedButton(
                onPressed: _goThisMonth,
                style: OutlinedButton.styleFrom(
                  foregroundColor: KanakkuTheme.ink,
                  side: BorderSide(color: KanakkuTheme.dividerColor),
                  backgroundColor: KanakkuTheme.card,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: const Text(
                  'This month',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          KCard(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => _shiftMonth(-1),
                      icon: const Icon(Icons.chevron_left),
                      tooltip: 'Previous month',
                      style: IconButton.styleFrom(
                        backgroundColor: KanakkuTheme.surfaceAlt,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        subMonthNames[_month.month - 1],
                        textAlign: TextAlign.center,
                        style: KanakkuTheme.sectionTitle(size: 19),
                      ),
                    ),
                    IconButton(
                      onPressed: () => _shiftMonth(1),
                      icon: const Icon(Icons.chevron_right),
                      tooltip: 'Next month',
                      style: IconButton.styleFrom(
                        backgroundColor: KanakkuTheme.surfaceAlt,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '$payCount payment${payCount == 1 ? '' : 's'} · '
                  '${KanakkuTheme.inr(rupeesFromPaise(payTotal))}',
                  style: KanakkuTheme.secondary(size: 13.5),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    for (final w in weekdayNames)
                      Expanded(
                        child: Text(
                          w,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: KanakkuTheme.inkSoft,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                for (var w = 0; w < weekCount; w++)
                  Row(
                    children: [
                      for (var d = 0; d < 7; d++)
                        Expanded(
                          child: _dayCell(
                            DateTime(
                              gridStart.year,
                              gridStart.month,
                              gridStart.day + w * 7 + d,
                            ),
                            byDate,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (selDate != null)
            Text(
              '${weekdayFull[selDate.weekday - 1].substring(0, 3)}, '
              '${selDate.day} ${subMonthAbbr[selDate.month - 1]}',
              style: KanakkuTheme.secondary(size: 13.5),
            ),
          const SizedBox(height: 8),
          KCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: selectedItems.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(
                      'No payments on this day.',
                      style: KanakkuTheme.secondary(size: 13.5),
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < selectedItems.length; i++) ...[
                        if (i > 0)
                          Divider(height: 1, color: KanakkuTheme.dividerColor),
                        _CalendarRow(item: selectedItems[i]),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// One day-list row: tile, name (+ "Renews" pill for renewals,
/// category line for transactions), amount on the right.
class _CalendarRow extends StatelessWidget {
  final CalendarItem item;
  const _CalendarRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final Widget tile;
    if (item.isRenewal) {
      final brand = brandFor(item.brandKey ?? 'custom', fallbackName: item.name);
      tile = Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: brand.tint,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(brand.icon, color: brand.fg, size: 22),
      );
    } else {
      tile = Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: KanakkuTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          _categoryIcon(item.category),
          color: KanakkuTheme.inkSoft,
          size: 22,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          tile,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                if (item.isRenewal)
                  PillBadge(
                    label: 'Renews',
                    background: KanakkuTheme.badgeGreenBg,
                    foreground: KanakkuTheme.badgeGreenFg,
                  )
                else if (item.category != null)
                  Text(
                    item.category!,
                    style: KanakkuTheme.secondary(size: 12.5),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            item.isCredit
                ? '+${KanakkuTheme.inr(rupeesFromPaise(item.amountPaise))}'
                : KanakkuTheme.inr(rupeesFromPaise(item.amountPaise)),
            style: KanakkuTheme.amount(
              size: 15.5,
              color: item.isCredit ? KanakkuTheme.credit : KanakkuTheme.ink,
            ),
          ),
        ],
      ),
    );
  }
}
