/// Budget alerts (v1.1, final_spec §4): 80% / 100% crossings of
/// per-category caps and of the optional overall monthly cap,
/// evaluated ONLY when the app is opened/used (decision #5 — the
/// honesty line "Budget alerts are checked when you open Kanakku —
/// not in real time" appears wherever alerts are described).
///
/// All money here is integer paise; percentages are integer maths
/// (spec §4.1: pct = spent*100 ~/ cap). The alert-state document is
/// device-local bookkeeping: it is never backed up (spec §2.3).
library;

import 'dart:convert';

import 'package:kanakku_parser/categorize.dart';

/// The normative honesty line (spec §4.5) — used verbatim in the
/// Budgets header, Settings, and the first-ever notification.
const budgetAlertHonestyLine =
    'Budget alerts are checked when you open Kanakku — not in real time.';

const overallAlertKey = '__overall__';
String categoryAlertKey(String category) => 'cat:$category';

// ---------------------------------------------------------------------
// Spend computation (spec §4.1)
// ---------------------------------------------------------------------

/// A transaction reduced to what alert maths needs.
class AlertTxn {
  final int amountPaise;
  final bool isDebit;
  final String category;
  final Bucket bucket;
  final DateTime at;
  const AlertTxn({
    required this.amountPaise,
    required this.isDebit,
    required this.category,
    required this.bucket,
    required this.at,
  });
}

bool _inWindow(AlertTxn t, DateTime start, DateTime end) =>
    !t.at.isBefore(start) && t.at.isBefore(end);

/// Per-category spent = debit amounts in the category inside the
/// budget month (the Budgets screen's existing definition).
Map<String, int> spentByCategoryPaise(
  List<AlertTxn> txns,
  DateTime start,
  DateTime end,
) {
  final out = <String, int>{};
  for (final t in txns) {
    if (!t.isDebit || !_inWindow(t, start, end)) continue;
    out[t.category] = (out[t.category] ?? 0) + t.amountPaise;
  }
  return out;
}

/// Overall spent (normative, spec §4.1): DEBIT amounts of ALL
/// transactions in the budget month regardless of category —
/// uncategorised included, credits never netted — except debits in
/// the `savings` bucket, which are excluded.
int overallSpentPaise(List<AlertTxn> txns, DateTime start, DateTime end) {
  var sum = 0;
  for (final t in txns) {
    if (!t.isDebit || !_inWindow(t, start, end)) continue;
    if (t.bucket == Bucket.savings) continue;
    sum += t.amountPaise;
  }
  return sum;
}

// ---------------------------------------------------------------------
// Alert state document (spec §2.3)
// ---------------------------------------------------------------------

Map<String, dynamic> decodeAlertState(String json) {
  try {
    final m = jsonDecode(json);
    if (m is Map) return Map<String, dynamic>.from(m);
  } catch (_) {}
  return <String, dynamic>{};
}

String encodeAlertState(Map<String, dynamic> state) => jsonEncode(state);

Map<String, dynamic> _meta(Map<String, dynamic> state) {
  final m = state['_meta'];
  if (m is Map) return (state['_meta'] = Map<String, dynamic>.from(m));
  return state['_meta'] = <String, dynamic>{};
}

Map<String, dynamic> _monthMap(Map<String, dynamic> state, String key) {
  final m = state[key];
  if (m is Map) return (state[key] = Map<String, dynamic>.from(m));
  return state[key] = <String, dynamic>{};
}

Map<String, dynamic> _thresholds(
  Map<String, dynamic> monthMap,
  String alertKey,
) {
  final m = monthMap[alertKey];
  if (m is Map) return (monthMap[alertKey] = Map<String, dynamic>.from(m));
  return monthMap[alertKey] = <String, dynamic>{
    '80': null,
    '100': null,
    'capPaise': 0,
  };
}

/// Thresholds (subset of {80, 100}) that have fired for [alertKey]
/// in [monthKey] — drives the Budgets-screen fired-state dot.
Set<int> firedThresholds(
  Map<String, dynamic> state,
  String monthKey,
  String alertKey,
) {
  final month = state[monthKey];
  if (month is! Map) return const {};
  final t = month[alertKey];
  if (t is! Map) return const {};
  return {
    if (t['80'] != null) 80,
    if (t['100'] != null) 100,
  };
}

/// Category rename (spec §2.3): the current month's alert state
/// follows the category to its new name, in the same user action
/// as the budgets_store cap move.
void renameCategoryAlertKey(
  Map<String, dynamic> state,
  String monthKey,
  String oldName,
  String newName,
) {
  final month = state[monthKey];
  if (month is! Map) return;
  final m = Map<String, dynamic>.from(month);
  final old = m.remove(categoryAlertKey(oldName));
  if (old != null) m[categoryAlertKey(newName)] = old;
  state[monthKey] = m;
}

/// Cap delete (spec §2.3): the category's current-month alert
/// state goes with the cap — re-adding the category later starts
/// with clean alert state (test T-B11).
void deleteCategoryAlertKey(
  Map<String, dynamic> state,
  String monthKey,
  String name,
) {
  final month = state[monthKey];
  if (month is! Map) return;
  final m = Map<String, dynamic>.from(month)..remove(categoryAlertKey(name));
  state[monthKey] = m;
}

// ---------------------------------------------------------------------
// Evaluation (spec §4.1–§4.3)
// ---------------------------------------------------------------------

class Crossing {
  final String alertKey;
  final String label; // category name, or 'Overall budget'
  final int threshold; // 80 | 100
  const Crossing(this.alertKey, this.label, this.threshold);
  String get line => '$label crossed $threshold%';
}

class BudgetAlertOutcome {
  /// The updated state document — the caller persists it, and
  /// persists AGAIN after [recordNotificationPosted] when a
  /// notification was actually posted.
  final Map<String, dynamic> state;
  final bool stateChanged;
  final List<Crossing> newCrossings;

  /// True when the caller should post ONE aggregated notification
  /// with [notificationTitle]/[notificationBody] (rules 1–4 have
  /// already been applied).
  final bool wantsNotification;
  final String? notificationTitle;
  final String? notificationBody;
  const BudgetAlertOutcome({
    required this.state,
    required this.stateChanged,
    required this.newCrossings,
    required this.wantsNotification,
    this.notificationTitle,
    this.notificationBody,
  });
}

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _prevMonthKey(String monthKey) {
  final p = monthKey.split('-');
  var y = int.tryParse(p[0]) ?? 2026, m = int.tryParse(p[1]) ?? 1;
  m -= 1;
  if (m < 1) {
    m = 12;
    y -= 1;
  }
  return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}';
}

BudgetAlertOutcome evaluateBudgetAlerts({
  required Map<String, dynamic> state,
  required String monthKey,
  required Map<String, int> capsPaise,
  required int? overallCapPaise,
  required Map<String, int> spentByCategory,
  required int overallSpent,
  required DateTime now,
  required bool alertsOn,
  required bool isForeground,
}) {
  final s = decodeAlertState(encodeAlertState(state));
  var changed = false;
  final crossings = <Crossing>[];

  // Prune months older than the previous budget month (spec §2.3).
  final keep = {monthKey, _prevMonthKey(monthKey)};
  for (final k in s.keys.toList()) {
    if (k != '_meta' && !keep.contains(k)) {
      s.remove(k);
      changed = true;
    }
  }

  final month = _monthMap(s, monthKey);
  final nowMs = now.millisecondsSinceEpoch;

  void evaluateTarget(String alertKey, String label, int spent, int cap) {
    if (cap <= 0) return;
    final th = _thresholds(month, alertKey);
    final pct = spent * 100 ~/ cap; // integer maths only (§4.1)
    final storedCap = (th['capPaise'] as num?)?.toInt() ?? 0;
    for (final t in const [100, 80]) {
      final key = '$t';
      if (pct >= t && th[key] == null) {
        th[key] = nowMs; // fires + records, whatever happens next
        crossings.add(Crossing(alertKey, label, t));
        changed = true;
      } else if (pct < t && th[key] != null && storedCap != cap) {
        // Re-arm ONLY when the crossing was caused by a cap change
        // (§4.2): spend decreases alone never re-arm.
        th[key] = null;
        changed = true;
      }
    }
    if (storedCap != cap) {
      th['capPaise'] = cap;
      changed = true;
    }
  }

  capsPaise.forEach((category, cap) {
    evaluateTarget(
      categoryAlertKey(category),
      category,
      spentByCategory[category] ?? 0,
      cap,
    );
  });
  if (overallCapPaise != null) {
    evaluateTarget(
      overallAlertKey,
      'Overall budget',
      overallSpent,
      overallCapPaise,
    );
  }

  // ---- Notification rules (§4.3). --------------------------------
  var wantsNotification = false;
  String? title, body;
  if (crossings.isNotEmpty) {
    final meta = _meta(s);
    if (!alertsOn) {
      // Rule 3: state still records; no notification, and rule-2
      // bookkeeping is skipped (no suppressed entries, no burst
      // when alerts are re-enabled).
    } else if (isForeground) {
      // Rule 4: no notification while the app is in the
      // foreground — the in-app banner carries these crossings.
    } else {
      final counts = meta['notifiedCountByDate'];
      final todayCount = counts is Map
          ? (counts[_dateStr(now)] as num?)?.toInt() ?? 0
          : 0;
      if (todayCount >= 2) {
        // Rule 2: the 3rd+ crossing today records state but posts
        // nothing; it is named in the next in-app banner instead.
        final supp = meta['suppressedCrossings'];
        final list = supp is List ? List<dynamic>.from(supp) : <dynamic>[];
        for (final c in crossings) {
          list.add({
            'key': c.alertKey,
            'threshold': c.threshold,
            'month': monthKey,
            'date': _dateStr(now),
          });
        }
        meta['suppressedCrossings'] = list;
        changed = true;
      } else {
        // Rule 1: at most ONE notification per evaluation,
        // aggregating all crossings.
        wantsNotification = true;
        title = 'Budget alert';
        final lines = [
          for (final c in crossings.take(3)) c.line,
          if (crossings.length > 3) '+${crossings.length - 3} more',
        ];
        if (meta['everNotified'] != true) {
          lines.add('Alerts are checked when you open Kanakku');
        }
        body = lines.join('\n');
      }
    }
  }

  return BudgetAlertOutcome(
    state: s,
    stateChanged: changed,
    newCrossings: crossings,
    wantsNotification: wantsNotification,
    notificationTitle: title,
    notificationBody: body,
  );
}

/// Bookkeeping after a notification was ACTUALLY posted (spec
/// §4.3 rule 2): bumps today's count (the only enforcer of the
/// 2/day cap), marks the first-ever notification as sent, and
/// prunes count dates older than 7 days.
void recordNotificationPosted(Map<String, dynamic> state, DateTime now) {
  final meta = _meta(state);
  final counts = meta['notifiedCountByDate'];
  final map = counts is Map
      ? Map<String, dynamic>.from(counts)
      : <String, dynamic>{};
  final today = _dateStr(now);
  map[today] = ((map[today] as num?)?.toInt() ?? 0) + 1;
  final cutoff = _dateStr(now.subtract(const Duration(days: 7)));
  map.removeWhere((k, _) => k.compareTo(cutoff) < 0);
  meta['notifiedCountByDate'] = map;
  meta['everNotified'] = true;
}

// ---------------------------------------------------------------------
// In-app banner (spec §4.4)
// ---------------------------------------------------------------------

/// Lines for the Home banner: today's unacknowledged crossings
/// plus any suppressed crossings, until dismissed. Empty when the
/// banner was already dismissed today.
List<String> bannerLines(
  Map<String, dynamic> state,
  String monthKey,
  DateTime now,
) {
  final meta = state['_meta'];
  if (meta is Map && meta['bannerDismissedOn'] == _dateStr(now)) {
    return const [];
  }
  final lines = <String>[];
  final month = state[monthKey];
  if (month is Map) {
    month.forEach((alertKey, v) {
      if (v is! Map) return;
      final label = alertKey == overallAlertKey
          ? 'Overall budget'
          : alertKey.toString().startsWith('cat:')
          ? alertKey.toString().substring(4)
          : alertKey.toString();
      for (final t in const [100, 80]) {
        final ts = (v['$t'] as num?)?.toInt();
        if (ts != null &&
            _dateStr(DateTime.fromMillisecondsSinceEpoch(ts)) ==
                _dateStr(now)) {
          lines.add('$label crossed $t%');
        }
      }
    });
  }
  if (meta is Map && meta['suppressedCrossings'] is List) {
    for (final e in meta['suppressedCrossings'] as List) {
      if (e is Map && e['month'] == monthKey) {
        final key = e['key']?.toString() ?? '';
        final label = key == overallAlertKey
            ? 'Overall budget'
            : key.startsWith('cat:')
            ? key.substring(4)
            : key;
        lines.add('$label crossed ${e['threshold']}%');
      }
    }
  }
  return lines;
}

/// Dismissing the banner acknowledges today's crossings and clears
/// the suppressed list it just showed (spec §4.4).
void dismissBanner(Map<String, dynamic> state, DateTime now) {
  final meta = _meta(state);
  meta['bannerDismissedOn'] = _dateStr(now);
  meta['suppressedCrossings'] = <dynamic>[];
}
