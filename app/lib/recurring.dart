/// Recurring transactions (v1.1, final_spec §2–§3):
/// expectation + reconciliation.
///
/// A RULE says "₹X leaves account …1234 for Rent around the 5th of
/// every month". The engine (run on app open, after captures load)
/// creates OCCURRENCES for due dates, then either matches each one
/// against a real captured payment or — once the grace window
/// closes — posts an ordinary manual entry for it, so the books are
/// complete either way and every payment is counted exactly once.
///
/// Everything here is pure Dart over the JSON document shapes: the
/// engine takes the decoded stores in and returns updated copies,
/// which keeps every rule in spec §3 unit-testable without a phone.
///
/// Dates are LOCAL calendar dates as 'yyyy-mm-dd' strings
/// everywhere in this file — never timestamps — so DST and timezone
/// offsets can never shift a due date.
library;

import 'dart:convert';

import 'package:kanakku_parser/kanakku_parser.dart';
import 'package:kanakku_parser/categorize.dart';

import 'manual.dart';
import 'money.dart';

// ---------------------------------------------------------------------
// Date helpers (local calendar dates as yyyy-mm-dd strings)
// ---------------------------------------------------------------------

String dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String todayStr(DateTime now) => dateStr(now);

/// Parses a yyyy-mm-dd string to a local-midnight DateTime; null on
/// anything malformed (defensive decode never throws, spec §2.1).
DateTime? parseDateStr(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s.trim());
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final dt = DateTime(y, mo, d);
  if (dt.year != y || dt.month != mo || dt.day != d) return null;
  return dt;
}

String addDaysStr(String s, int n) {
  final d = parseDateStr(s);
  if (d == null) return s;
  return dateStr(DateTime(d.year, d.month, d.day + n));
}

/// Whole days from [a] to [b] (b − a), both yyyy-mm-dd.
int daysBetween(String a, String b) {
  final da = parseDateStr(a), db = parseDateStr(b);
  if (da == null || db == null) return 0;
  return DateTime.utc(db.year, db.month, db.day)
      .difference(DateTime.utc(da.year, da.month, da.day))
      .inDays;
}

int lastDayOfMonth(int year, int month) => DateTime(year, month + 1, 0).day;

// ---------------------------------------------------------------------
// Store document (spec §2.1)
// ---------------------------------------------------------------------

const emptyRecurringStoreJson = '{"nextRuleSeq":1,"rules":[]}';

Map<String, dynamic> emptyRecurringStore() => {
  'nextRuleSeq': 1,
  'rules': <Map<String, dynamic>>[],
};

int _asInt(Object? v, int dflt) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? dflt : dflt);

String _asStr(Object? v, String dflt) {
  final s = v?.toString();
  return (s == null || s.isEmpty) ? dflt : s;
}

/// Grace days are bounded 0–14 (decision #7) — clamped on read as
/// well as on write, so a hand-edited store cannot widen a window
/// (test T-R18).
int clampGraceDays(Object? v) {
  final g = _asInt(v, 3);
  return g < 0 ? 0 : (g > 14 ? 14 : g);
}

const _occStates = {
  'pending',
  'posted',
  'matched',
  'skipped',
  'flagged',
  'resolved',
};

Map<String, dynamic> _normalizeOccurrence(
  Map<String, dynamic> o,
  int ruleAmountPaise,
) {
  final state = o['state']?.toString();
  return {
    'date': _asStr(o['date'], ''),
    // The SNAPSHOT is normative (spec §2.1): matching and posting
    // use this, never the rule's current amount.
    'amountPaise': _asInt(o['amountPaise'], ruleAmountPaise),
    'state': _occStates.contains(state) ? state : 'pending',
    if (o['entryId'] != null) 'entryId': o['entryId'].toString(),
    if (o['captureKey'] != null) 'captureKey': o['captureKey'].toString(),
    if (o['resolvedAt'] != null) 'resolvedAt': _asInt(o['resolvedAt'], 0),
    if (o['flagReason'] != null) 'flagReason': o['flagReason'].toString(),
    if (o['flagCandidates'] is List)
      'flagCandidates': [
        for (final c in o['flagCandidates'] as List) c.toString(),
      ],
  };
}

Map<String, dynamic> normalizeRule(Map<String, dynamic> r) {
  final label = _asStr(r['label'], '');
  final interval = r['interval'] is Map
      ? Map<String, dynamic>.from(r['interval'] as Map)
      : <String, dynamic>{};
  final type = interval['type']?.toString();
  final amountPaise = _asInt(r['amountPaise'], 0);
  final occs = <Map<String, dynamic>>[];
  if (r['occurrences'] is List) {
    for (final o in r['occurrences'] as List) {
      if (o is Map) {
        occs.add(
          _normalizeOccurrence(
            Map<String, dynamic>.from(o),
            amountPaise,
          ),
        );
      }
    }
  }
  final spans = <Map<String, dynamic>>[];
  if (r['pauseSpans'] is List) {
    for (final s in r['pauseSpans'] as List) {
      if (s is Map) {
        spans.add({
          'from': _asStr(s['from'], ''),
          if (s['to'] != null) 'to': s['to'].toString(),
        });
      }
    }
  }
  final status = r['status']?.toString();
  return {
    'id': _asStr(r['id'], ''),
    'label': label,
    'matchText': r['matchText']?.toString() ?? label,
    'amountPaise': amountPaise,
    'dir': r['dir']?.toString() == 'credit' ? 'credit' : 'debit',
    'category': _asStr(r['category'], label),
    'bucket': _asStr(r['bucket'], 'needs'),
    'mode': _asStr(r['mode'], 'Cash'),
    if (r['accountLast4'] != null &&
        r['accountLast4'].toString().isNotEmpty)
      'accountLast4': r['accountLast4'].toString(),
    if (r['note'] != null && r['note'].toString().isNotEmpty)
      'note': r['note'].toString(),
    'interval': {
      'type': const {
        'daily',
        'weekly',
        'monthly',
        'customDays',
      }.contains(type)
          ? type
          : 'monthly',
      'every': _asInt(interval['every'], 1) < 1
          ? 1
          : _asInt(interval['every'], 1),
      if (interval['weekday'] != null)
        'weekday': _asInt(interval['weekday'], 1),
      if (interval['dayOfMonth'] != null)
        'dayOfMonth': _asInt(interval['dayOfMonth'], 1),
    },
    'startDate': _asStr(r['startDate'], ''),
    if (r['endDate'] != null) 'endDate': r['endDate'].toString(),
    if (r['maxCount'] != null) 'maxCount': _asInt(r['maxCount'], 0),
    // Monotonic, persisted (spec §2.1): incremented exactly once
    // when an occurrence fires; never derived from the (pruned)
    // occurrence list, never decremented.
    'firedCount': _asInt(r['firedCount'], 0) < 0
        ? 0
        : _asInt(r['firedCount'], 0),
    if (r['lastFiredDate'] != null)
      'lastFiredDate': r['lastFiredDate'].toString(),
    'status': const {'active', 'paused', 'ended'}.contains(status)
        ? status
        : 'active',
    'capturePolicy': r['capturePolicy']?.toString() == 'auto'
        ? 'auto'
        : 'matchOrPost',
    'graceDays': clampGraceDays(r['graceDays']),
    'restoredHold': r['restoredHold'] == true,
    if (r['holdReviewed'] == true) 'holdReviewed': true,
    'createdAt': _asInt(r['createdAt'], 0),
    'updatedAt': _asInt(r['updatedAt'], 0),
    if (r['lastCreatedDate'] != null)
      'lastCreatedDate': r['lastCreatedDate'].toString(),
    'pauseSpans': spans,
    'occurrences': occs,
  };
}

/// Decodes the recurring_store document. Defensive: any malformed
/// content degrades to the empty document rather than throwing
/// (spec §2.1).
Map<String, dynamic> decodeRecurringStore(String json) {
  try {
    final m = jsonDecode(json);
    if (m is Map) {
      final doc = Map<String, dynamic>.from(m);
      final rules = <Map<String, dynamic>>[];
      if (doc['rules'] is List) {
        for (final r in doc['rules'] as List) {
          if (r is Map) {
            rules.add(normalizeRule(Map<String, dynamic>.from(r)));
          }
        }
      }
      final seq = _asInt(doc['nextRuleSeq'], 1);
      return {'nextRuleSeq': seq < 1 ? 1 : seq, 'rules': rules};
    }
  } catch (_) {}
  return emptyRecurringStore();
}

String encodeRecurringStore(Map<String, dynamic> doc) => jsonEncode(doc);

List<Map<String, dynamic>> rulesOf(Map<String, dynamic> doc) =>
    (doc['rules'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic>? ruleById(Map<String, dynamic> doc, String id) {
  for (final r in rulesOf(doc)) {
    if (r['id'] == id) return r;
  }
  return null;
}

/// Allocates a rule id: 'rec_' + base36(createdAtMs) + '_' + the
/// persisted monotonic sequence (spec §2.1 — never derived from the
/// rules list, so deleting a rule can never reuse an id).
String newRuleId(Map<String, dynamic> doc, int createdAtMs) {
  final seq = _asInt(doc['nextRuleSeq'], 1);
  doc['nextRuleSeq'] = seq + 1;
  return 'rec_${createdAtMs.toRadixString(36)}_$seq';
}

List<Map<String, dynamic>> occurrencesOf(Map<String, dynamic> rule) =>
    (rule['occurrences'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic>? occurrenceOn(Map<String, dynamic> rule, String date) {
  for (final o in occurrencesOf(rule)) {
    if (o['date'] == date) return o;
  }
  return null;
}

Map<String, dynamic> newOccurrence(String date, int amountPaise) => {
  'date': date,
  'amountPaise': amountPaise,
  'state': 'pending',
};

/// Builds a complete rule map with spec defaults (used by the
/// create form and by tests).
Map<String, dynamic> newRule({
  required String id,
  required String label,
  required int amountPaise,
  required String dir,
  required String category,
  required String bucket,
  required String mode,
  required Map<String, dynamic> interval,
  required String startDate,
  String? matchText,
  String? accountLast4,
  String? note,
  String? endDate,
  int? maxCount,
  String capturePolicy = 'matchOrPost',
  int graceDays = 3,
  required int nowMs,
}) => normalizeRule({
  'id': id,
  'label': label,
  'matchText': matchText ?? label,
  'amountPaise': amountPaise,
  'dir': dir,
  'category': category,
  'bucket': bucket,
  'mode': mode,
  if (accountLast4 != null && accountLast4.isNotEmpty)
    'accountLast4': accountLast4,
  if (note != null && note.isNotEmpty) 'note': note,
  'interval': interval,
  'startDate': startDate,
  'endDate': ?endDate,
  'maxCount': ?maxCount,
  'firedCount': 0,
  'status': 'active',
  'capturePolicy': capturePolicy,
  'graceDays': graceDays,
  'restoredHold': false,
  'createdAt': nowMs,
  'updatedAt': nowMs,
  'pauseSpans': <Map<String, dynamic>>[],
  'occurrences': <Map<String, dynamic>>[],
});

/// Credit rules can never use plain `auto` (spec §3.6): an expected
/// credit that never arrives must be confirmed by the user, never
/// silently booked as income.
bool effectiveAuto(Map<String, dynamic> rule) =>
    rule['capturePolicy'] == 'auto' && rule['dir'] != 'credit';

// ---------------------------------------------------------------------
// Schedule maths (spec §3.4) — pure over date strings
// ---------------------------------------------------------------------

/// Every due date of [rule] in (fromExclusive, toInclusive].
/// "Fired" bookkeeping lives elsewhere; this is only the calendar.
List<String> dueDates(
  Map<String, dynamic> rule,
  String fromExclusive,
  String toInclusive,
) {
  final start = parseDateStr(_asStr(rule['startDate'], ''));
  if (start == null) return const [];
  final from = parseDateStr(fromExclusive);
  final to = parseDateStr(toInclusive);
  if (to == null) return const [];
  final interval = (rule['interval'] as Map).cast<String, dynamic>();
  final type = interval['type']?.toString() ?? 'monthly';
  var every = _asInt(interval['every'], 1);
  if (every < 1) every = 1;
  final out = <String>[];
  bool inRange(DateTime d) =>
      (from == null || d.isAfter(from)) && !d.isAfter(to);
  if (type == 'daily' || type == 'customDays') {
    var d = start;
    while (!d.isAfter(to)) {
      if (inRange(d)) out.add(dateStr(d));
      d = DateTime(d.year, d.month, d.day + every);
    }
  } else if (type == 'weekly') {
    var wd = _asInt(interval['weekday'], start.weekday);
    if (wd < 1 || wd > 7) wd = start.weekday;
    var d = start;
    while (d.weekday != wd) {
      d = DateTime(d.year, d.month, d.day + 1);
    }
    while (!d.isAfter(to)) {
      if (inRange(d)) out.add(dateStr(d));
      d = DateTime(d.year, d.month, d.day + 7 * every);
    }
  } else {
    // monthly: nominal day each time, clamped to the month's last
    // day — Jan 31 → Feb 28/29 → Mar 31, no drift (spec §3.4).
    var dom = _asInt(interval['dayOfMonth'], start.day);
    if (dom < 1) dom = 1;
    if (dom > 31) dom = 31;
    var monthIdx = start.year * 12 + (start.month - 1);
    final endIdx = to.year * 12 + (to.month - 1);
    while (monthIdx <= endIdx) {
      final y = monthIdx ~/ 12, m = monthIdx % 12 + 1;
      final day = dom <= lastDayOfMonth(y, m) ? dom : lastDayOfMonth(y, m);
      final d = DateTime(y, m, day);
      if (!d.isBefore(start) && inRange(d)) out.add(dateStr(d));
      monthIdx += every;
    }
  }
  return out;
}

/// Human schedule for lists, e.g. "Monthly on the 5th" (spec §3.1).
String humanSchedule(Map<String, dynamic> rule) {
  final interval = (rule['interval'] as Map).cast<String, dynamic>();
  final type = interval['type']?.toString() ?? 'monthly';
  final every = _asInt(interval['every'], 1);
  final start = parseDateStr(_asStr(rule['startDate'], ''));
  switch (type) {
    case 'daily':
      return every <= 1 ? 'Daily' : 'Every $every days';
    case 'customDays':
      return 'Every $every days';
    case 'weekly':
      const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      var wd = _asInt(interval['weekday'], start?.weekday ?? 1);
      if (wd < 1 || wd > 7) wd = 1;
      return every <= 1
          ? 'Weekly on ${names[wd - 1]}'
          : 'Every $every weeks on ${names[wd - 1]}';
    default:
      var dom = _asInt(interval['dayOfMonth'], start?.day ?? 1);
      if (dom < 1) dom = 1;
      if (dom > 31) dom = 31;
      return every <= 1
          ? 'Monthly on the ${_ordinal(dom)}'
          : 'Every $every months on the ${_ordinal(dom)}';
  }
}

String _ordinal(int d) {
  if (d >= 11 && d <= 13) return '${d}th';
  return switch (d % 10) {
    1 => '${d}st',
    2 => '${d}nd',
    3 => '${d}rd',
    _ => '${d}th',
  };
}

/// The next due date that has not been created yet, or null when
/// the rule has ended / has no future dates within a year.
String? nextDueDate(Map<String, dynamic> rule, String today) {
  if (rule['status'] == 'ended') return null;
  final start = _asStr(rule['startDate'], '');
  if (start.isEmpty) return null;
  final lastCreated = rule['lastCreatedDate']?.toString();
  final from = lastCreated ?? addDaysStr(start, -1);
  final end = rule['endDate']?.toString();
  final dates = dueDates(rule, from, addDaysStr(today, 370));
  for (final d in dates) {
    if (end != null && d.compareTo(end) > 0) break;
    return d;
  }
  return null;
}

// ---------------------------------------------------------------------
// Pruning (spec §2.1.1) — applied on every store write
// ---------------------------------------------------------------------

/// Keeps an occurrence when it is pending/flagged (never pruned),
/// OR its date is within the last 45 days, OR it is among the 60
/// most recent for the rule.
void pruneOccurrences(Map<String, dynamic> rule, String today) {
  final occs = occurrencesOf(rule);
  // With ≤60 occurrences, the "60 most recent" clause already
  // keeps every one of them — nothing can be pruned.
  if (occs.length <= 60) return;
  final cutoff = addDaysStr(today, -45);
  final sorted = [...occs]..sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
  final recent = sorted.take(60).map((o) => identityHashCode(o)).toSet();
  rule['occurrences'] = [
    for (final o in occs)
      if (o['state'] == 'pending' ||
          o['state'] == 'flagged' ||
          (o['date'] as String).compareTo(cutoff) >= 0 ||
          recent.contains(identityHashCode(o)))
        o,
  ];
}

void pruneStore(Map<String, dynamic> doc, String today) {
  for (final r in rulesOf(doc)) {
    pruneOccurrences(r, today);
  }
}

// ---------------------------------------------------------------------
// Capture matching (spec §3.2)
// ---------------------------------------------------------------------

/// One captured transaction as the matcher sees it.
class CaptureView {
  final ParsedTransaction txn;
  final String key; // entryId — the captureKey stored on a match
  final int amountPaise;
  final String localDate;
  const CaptureView(this.txn, this.key, this.amountPaise, this.localDate);
}

CaptureView viewOf(ParsedTransaction t) => CaptureView(
  t,
  entryId(t),
  paiseFromRupees(t.amount),
  dateStr(t.receivedAt),
);

/// Group key: (amountPaise, accountLast4, localDate) — spec §3.2.
String captureGroupKey(CaptureView c) =>
    '${c.amountPaise}|${c.txn.accountLast4 ?? ''}|${c.localDate}';

Map<String, List<CaptureView>> groupCaptures(List<CaptureView> caps) {
  final out = <String, List<CaptureView>>{};
  for (final c in caps) {
    out.putIfAbsent(captureGroupKey(c), () => []).add(c);
  }
  return out;
}

/// The canonical match window (the ONLY definition, spec §3.2):
/// capture date C is in-window for due date D with grace g iff
/// D−3d ≤ C ≤ D+g.
bool inMatchWindow(String captureDate, String dueDate, int graceDays) {
  final c = daysBetween(dueDate, captureDate);
  return c >= -3 && c <= graceDays;
}

/// The §3.2 match test. [occAmountPaise] is the occurrence
/// SNAPSHOT. An empty matchText (after trim) matches NOTHING.
bool captureMatches(
  Map<String, dynamic> rule,
  int occAmountPaise,
  CaptureView c,
) {
  if (c.txn.direction.name != rule['dir']) return false;
  if (c.amountPaise != occAmountPaise) return false;
  final last4 = rule['accountLast4']?.toString();
  if (last4 != null && last4.isNotEmpty && c.txn.accountLast4 != last4) {
    return false;
  }
  final matchText = (rule['matchText']?.toString() ?? '').trim();
  if (matchText.isEmpty) return false;
  final party = c.txn.counterparty;
  if (party != null && party.isNotEmpty) {
    if (!party.toLowerCase().contains(matchText.toLowerCase())) {
      return false;
    }
  }
  return true;
}

/// Strong match (sweep only, spec §3.2): exact paise AND account
/// last4 equal (both present) AND (upiRef present and equal OR
/// counterparty exactly equal after trim + case-fold).
bool isStrongMatch(Map<String, dynamic> rule, Map<String, dynamic> occ, CaptureView c) {
  if (c.amountPaise != _asInt(occ['amountPaise'], 0)) return false;
  final last4 = rule['accountLast4']?.toString();
  if (last4 == null || last4.isEmpty) return false;
  if (c.txn.accountLast4 == null || c.txn.accountLast4 != last4) {
    return false;
  }
  // The generated entry carries no upiRef of its own; the "equal"
  // ref test compares the capture's ref against the ref recorded
  // for this occurrence when one was stored (flag candidates from
  // an earlier pass). In practice the counterparty-exact arm is
  // the one that fires for sweep candidates.
  final ref = occ['upiRef']?.toString();
  if (ref != null && ref.isNotEmpty && c.txn.upiRef == ref) return true;
  final party = c.txn.counterparty?.trim().toLowerCase();
  final matchText = (rule['matchText']?.toString() ?? '').trim().toLowerCase();
  if (party != null && party.isNotEmpty && matchText.isNotEmpty && party == matchText) {
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------
// The engine pass (spec §3.3)
// ---------------------------------------------------------------------

/// Outcome of one engine pass. [store] and [manualMaps] are the
/// (possibly mutated) working copies — the caller persists whichever
/// changed. [notices] are one-per-rule in-app notices (step 0).
class RecurringPassResult {
  final Map<String, dynamic> store;
  final List<Map<String, dynamic>> manualMaps;
  final bool storeChanged;
  final bool manualChanged;
  final List<String> notices;
  const RecurringPassResult({
    required this.store,
    required this.manualMaps,
    required this.storeChanged,
    required this.manualChanged,
    required this.notices,
  });
}

/// Runs one full engine pass (spec §3.3, steps 0–6).
///
/// [captures] are the parsed real transactions; [removedIds] are
/// entry ids the user has removed — a removed capture is not a real
/// payment, and a removed generated entry counts as deleted.
/// Pure: no I/O, no clock beyond [now].
RecurringPassResult runRecurringPass({
  required Map<String, dynamic> store,
  required List<Map<String, dynamic>> manualMaps,
  required List<ParsedTransaction> captures,
  required Set<String> removedIds,
  required DateTime now,
}) {
  final today = todayStr(now);
  final bound = addDaysStr(today, -90); // decision #1: 90-day bound
  final doc = decodeRecurringStore(encodeRecurringStore(store));
  final maps = [
    for (final m in manualMaps) Map<String, dynamic>.from(m),
  ];
  var storeChanged = false;
  var manualChanged = false;
  final notices = <String>[];

  // Manual-entry index by entry id (removed ids count as absent).
  final manualIndex = <String, Map<String, dynamic>>{};
  for (final m in maps) {
    final id = entryId(manualTxnFromJson(m));
    if (!removedIds.contains(id)) manualIndex.putIfAbsent(id, () => m);
  }

  // Captures: removed ones are not real payments (§1.2).
  final views = <CaptureView>[];
  for (final t in captures) {
    final v = viewOf(t);
    if (!removedIds.contains(v.key)) views.add(v);
  }
  final groups = groupCaptures(views);
  // A capture already recorded as some occurrence's captureKey is
  // consumed forever (spec §3.3 steps 1/4, test T-R10b).
  final consumedCaptures = <String>{
    for (final r in rulesOf(doc))
      for (final o in occurrencesOf(r))
        if (o['captureKey'] != null) o['captureKey'] as String,
  };
  final consumedGroups = <String>{};

  Map<String, dynamic> buildEntryMap(
    Map<String, dynamic> rule,
    Map<String, dynamic> occ,
  ) {
    final due = parseDateStr(occ['date'] as String) ?? now;
    final dir = rule['dir'] == 'credit'
        ? TxnDirection.credit
        : TxnDirection.debit;
    Bucket? bucket;
    for (final b in Bucket.values) {
      if (b.name == rule['bucket']) bucket = b;
    }
    return manualToJson(
      amount: rupeesFromPaise(_asInt(occ['amountPaise'], 0)),
      label: rule['label'] as String,
      at: DateTime(due.year, due.month, due.day, 12),
      direction: dir,
      note: rule['note']?.toString(),
      bucket: bucket,
      mode: rule['mode']?.toString(),
      origin: 'recurring',
      recurringId: rule['id'] as String,
      occurrenceDate: occ['date'] as String,
      postedAtMs: now.millisecondsSinceEpoch,
    );
  }

  /// Posts the manual entry for an occurrence (spec §2.2/§3.3
  /// step 6 crash healing: an already-present deterministic entry
  /// is recognised, never duplicated). The entry id is computed
  /// from the built map, exactly as the loader will compute it.
  void postEntry(Map<String, dynamic> rule, Map<String, dynamic> occ) {
    final map = buildEntryMap(rule, occ);
    final id = entryId(manualTxnFromJson(map));
    occ['entryId'] = id;
    if (manualIndex.containsKey(id)) return; // already posted
    maps.add(map);
    manualIndex[id] = map;
    manualChanged = true;
  }

  void fire(Map<String, dynamic> rule, Map<String, dynamic> occ) {
    rule['firedCount'] = _asInt(rule['firedCount'], 0) + 1;
    rule['lastFiredDate'] = occ['date'];
  }

  bool inPauseSpan(Map<String, dynamic> rule, String date) {
    for (final s in (rule['pauseSpans'] as List).cast<Map<String, dynamic>>()) {
      final from = s['from']?.toString() ?? '';
      final to = s['to']?.toString();
      if (from.isNotEmpty &&
          date.compareTo(from) >= 0 &&
          (to == null || date.compareTo(to) <= 0)) {
        return true;
      }
    }
    return false;
  }

  bool processable(Map<String, dynamic> rule) =>
      rule['status'] == 'active' && rule['restoredHold'] != true;

  final rules = rulesOf(doc);

  // ---- Step 0: the 90-day bound, BEFORE any posting (§3.3). ------
  // Processable rules only: a paused rule's pending occurrences
  // stay pending until resume (§3.5), then the bound applies.
  for (final rule in rules) {
    if (!processable(rule)) continue;
    var skipped = 0;
    for (final occ in occurrencesOf(rule)) {
      if (occ['state'] == 'pending' &&
          (occ['date'] as String).compareTo(bound) < 0) {
        occ['state'] = 'skipped';
        skipped++;
        storeChanged = true;
      }
    }
    if (skipped > 0) {
      notices.add(
        '$skipped older occurrence${skipped == 1 ? '' : 's'} of '
        '"${rule['label']}" skipped (over 90 days old)',
      );
    }
  }

  // ---- Pause-span recording (§3.5): due dates inside a pause are
  // recorded skipped — never fired, never caught up. Runs for
  // active and paused rules alike (first pass that observes the
  // span), creating the skipped occurrences ahead of step 3.
  for (final rule in rules) {
    if (rule['status'] == 'ended') continue;
    final spans = (rule['pauseSpans'] as List)
        .cast<Map<String, dynamic>>();
    if (spans.isEmpty) continue;
    final lastCreated = rule['lastCreatedDate']?.toString();
    final start = _asStr(rule['startDate'], '');
    if (start.isEmpty) continue;
    final from = lastCreated ?? addDaysStr(start, -1);
    for (final d in dueDates(rule, from, today)) {
      if (!inPauseSpan(rule, d)) continue;
      if (occurrenceOn(rule, d) != null) continue;
      final occ = newOccurrence(d, _asInt(rule['amountPaise'], 0));
      occ['state'] = 'skipped';
      occurrencesOf(rule).add(occ);
      storeChanged = true;
    }
  }

  // ---- Step 3 (creation half): create occurrences for due dates
  // up to today. Auto rules post immediately; matchOrPost rules
  // start pending and go through step 1 in this same pass.
  for (final rule in rules) {
    if (!processable(rule)) continue;
    final start = _asStr(rule['startDate'], '');
    if (start.isEmpty) continue;
    final endDate = rule['endDate']?.toString();
    final maxCount = rule['maxCount'] == null
        ? null
        : _asInt(rule['maxCount'], 0);
    final lastCreated = rule['lastCreatedDate']?.toString();
    final from = lastCreated ?? addDaysStr(start, -1);
    var created = 0, skippedOld = 0;
    for (final d in dueDates(rule, from, today)) {
      if (endDate != null && d.compareTo(endDate) > 0) break;
      if (maxCount != null &&
          _asInt(rule['firedCount'], 0) +
                  occurrencesOf(rule)
                      .where(
                        (o) =>
                            o['state'] == 'pending' ||
                            o['state'] == 'flagged',
                      )
                      .length >=
              maxCount) {
        break; // enough fired + in-flight; step 5 ends the rule
      }
      rule['lastCreatedDate'] = d;
      storeChanged = true;
      if (occurrenceOn(rule, d) != null) continue; // pause-span pass
      final occ = newOccurrence(d, _asInt(rule['amountPaise'], 0));
      occurrencesOf(rule).add(occ);
      created++;
      if (d.compareTo(bound) < 0) {
        occ['state'] = 'skipped'; // step 0 bound on creation
        skippedOld++;
      } else if (inPauseSpan(rule, d)) {
        occ['state'] = 'skipped';
      } else if (effectiveAuto(rule)) {
        postEntry(rule, occ);
        occ['state'] = 'posted';
        fire(rule, occ);
      }
      // else: stays pending for step 1 below.
    }
    if (skippedOld > 0) {
      notices.add(
        '$skippedOld older occurrence${skippedOld == 1 ? '' : 's'} of '
        '"${rule['label']}" skipped (over 90 days old)',
      );
    }
    if (created > 0) storeChanged = true;
  }

  // ---- Step 1: resolve pending occurrences, oldest first. --------
  final pending = <(Map<String, dynamic>, Map<String, dynamic>)>[];
  for (final rule in rules) {
    if (!processable(rule)) continue;
    for (final occ in occurrencesOf(rule)) {
      if (occ['state'] == 'pending') pending.add((rule, occ));
    }
  }
  pending.sort(
    (a, b) => (a.$2['date'] as String).compareTo(b.$2['date'] as String),
  );

  List<(String, CaptureView)> candidatesFor(
    Map<String, dynamic> rule,
    Map<String, dynamic> occ,
  ) {
    final out = <(String, CaptureView)>[];
    final grace = clampGraceDays(rule['graceDays']);
    groups.forEach((gKey, caps) {
      if (consumedGroups.contains(gKey)) return;
      for (final c in caps) {
        if (consumedCaptures.contains(c.key)) continue;
        if (!inMatchWindow(c.localDate, occ['date'] as String, grace)) {
          continue;
        }
        if (captureMatches(rule, _asInt(occ['amountPaise'], 0), c)) {
          out.add((gKey, c));
        }
      }
    });
    return out;
  }

  // Contested groups, from the PRE-PASS snapshot: a group is
  // contested for a due date when two or more pending occurrences
  // share that due date and can all match it — no preference
  // exists, so every suitor flags (§3.2). A snapshot is required:
  // once the first suitor flags, a live re-check would wrongly
  // let the second one match.
  final contested = <String, Set<String>>{}; // groupKey → dueDates
  {
    final byGroup = <String, Map<String, int>>{};
    for (final (rule, occ) in pending) {
      final grace = clampGraceDays(rule['graceDays']);
      groups.forEach((gKey, caps) {
        var hit = false;
        for (final c in caps) {
          if (consumedCaptures.contains(c.key)) continue;
          if (!inMatchWindow(c.localDate, occ['date'] as String, grace)) {
            continue;
          }
          if (captureMatches(rule, _asInt(occ['amountPaise'], 0), c)) {
            hit = true;
            break;
          }
        }
        if (hit) {
          final m = byGroup.putIfAbsent(gKey, () => {});
          final d = occ['date'] as String;
          m[d] = (m[d] ?? 0) + 1;
        }
      });
    }
    byGroup.forEach((gKey, dates) {
      final bad = {
        for (final e in dates.entries)
          if (e.value >= 2) e.key,
      };
      if (bad.isNotEmpty) contested[gKey] = bad;
    });
  }

  for (final (rule, occ) in pending) {
    if (occ['state'] != 'pending') continue; // resolved as a rival
    final cands = candidatesFor(rule, occ);
    if (cands.isEmpty) {
      // Step 2: window closed with no match → post (or credit flag).
      final grace = clampGraceDays(rule['graceDays']);
      if (daysBetween(occ['date'] as String, today) > grace) {
        if (rule['dir'] == 'credit') {
          occ['state'] = 'flagged';
          occ['flagReason'] = 'creditUnseen';
        } else {
          postEntry(rule, occ);
          occ['state'] = 'posted';
          fire(rule, occ);
        }
        storeChanged = true;
      }
      continue;
    }
    final groupKeys = {for (final c in cands) c.$1};
    final rival = groupKeys.any(
      (g) => contested[g]?.contains(occ['date']) ?? false,
    );
    final ambiguous =
        groupKeys.length > 1 || cands.length > 1 || rival;
    if (ambiguous) {
      occ['state'] = 'flagged';
      occ['flagReason'] = 'ambiguousMatch';
      occ['flagCandidates'] = [for (final c in cands) c.$2.key];
      storeChanged = true;
    } else {
      final (gKey, cap) = cands.single;
      occ['state'] = 'matched';
      occ['captureKey'] = cap.key;
      consumedCaptures.add(cap.key);
      consumedGroups.add(gKey);
      fire(rule, occ);
      storeChanged = true;
    }
  }

  // ---- Step 4: late-match sweep over posted occurrences (≤35d). --
  final sweepFrom = addDaysStr(today, -35);
  for (final rule in rules) {
    if (!processable(rule)) continue;
    for (final occ in occurrencesOf(rule)) {
      if (occ['state'] != 'posted') continue;
      final date = occ['date'] as String;
      if (date.compareTo(sweepFrom) < 0) continue;
      final entryIdStored = occ['entryId']?.toString();
      final entryMap =
          entryIdStored == null ? null : manualIndex[entryIdStored];
      if (entryMap == null) continue; // user deleted it — §2.2
      final grace = clampGraceDays(rule['graceDays']);
      final strong = <CaptureView>[];
      final weak = <CaptureView>[];
      for (final c in views) {
        if (consumedCaptures.contains(c.key)) continue;
        if (!inMatchWindow(c.localDate, date, grace)) continue;
        if (!captureMatches(rule, _asInt(occ['amountPaise'], 0), c)) {
          continue;
        }
        (isStrongMatch(rule, occ, c) ? strong : weak).add(c);
      }
      if (strong.length == 1 && entryMap['editedByUser'] != true) {
        // The real payment arrived: remove the generated entry so
        // the payment is counted exactly once (§1.2/§3.3 step 4).
        maps.remove(entryMap);
        manualIndex.remove(entryIdStored);
        manualChanged = true;
        occ['state'] = 'matched';
        occ['captureKey'] = strong.single.key;
        consumedCaptures.add(strong.single.key);
        storeChanged = true;
      } else if (strong.isNotEmpty || weak.isNotEmpty) {
        // Possible duplicate — a human decides. Weak/fuzzy matches
        // NEVER delete an entry on their own.
        occ['state'] = 'flagged';
        occ['flagReason'] = 'possibleDuplicate';
        occ['flagCandidates'] = [
          for (final c in [...strong, ...weak]) c.key,
        ];
        storeChanged = true;
      }
    }
  }

  // ---- Step 5: stop conditions. ----------------------------------
  for (final rule in rules) {
    if (rule['status'] == 'ended') continue;
    final maxCount = rule['maxCount'] == null
        ? null
        : _asInt(rule['maxCount'], 0);
    final endDate = rule['endDate']?.toString();
    if (maxCount != null && _asInt(rule['firedCount'], 0) >= maxCount) {
      rule['status'] = 'ended';
      for (final occ in occurrencesOf(rule)) {
        if (occ['state'] == 'pending') occ['state'] = 'skipped';
      }
      storeChanged = true;
    } else if (endDate != null &&
        today.compareTo(endDate) > 0 &&
        !occurrencesOf(rule).any((o) => o['state'] == 'pending')) {
      rule['status'] = 'ended';
      storeChanged = true;
    }
  }

  // ---- Step 6: prune, then the caller persists once. -------------
  pruneStore(doc, today);
  for (final rule in rules) {
    rule['updatedAt'] = now.millisecondsSinceEpoch;
  }
  return RecurringPassResult(
    store: doc,
    manualMaps: maps,
    storeChanged: storeChanged,
    manualChanged: manualChanged,
    notices: notices,
  );
}

// ---------------------------------------------------------------------
// Flag resolutions (spec §3.3 step 4 / §3.6) — shared by UI + tests
// ---------------------------------------------------------------------

/// "This one is the payment" for an ambiguous-match flag: consumes
/// exactly that capture; the payment is counted once (§1.2).
bool resolveFlaggedMatch(
  Map<String, dynamic> store,
  String ruleId,
  String date,
  String captureKey,
) {
  final rule = ruleById(store, ruleId);
  final occ = rule == null ? null : occurrenceOn(rule, date);
  if (rule == null || occ == null || occ['state'] != 'flagged') {
    return false;
  }
  occ['state'] = 'matched';
  occ['captureKey'] = captureKey;
  occ['resolvedAt'] = DateTime.now().millisecondsSinceEpoch;
  occ.remove('flagReason');
  occ.remove('flagCandidates');
  rule['firedCount'] = _asInt(rule['firedCount'], 0) + 1;
  rule['lastFiredDate'] = date;
  return true;
}

/// Duplicate-flag resolution (spec §3.3 step 4): "Keep both" leaves
/// the generated entry; "Remove generated" deletes it and lets the
/// capture be the record. Either way the occurrence is `resolved`
/// — terminal, never re-flagged or re-swept.
bool resolveFlaggedDuplicate(
  Map<String, dynamic> store,
  List<Map<String, dynamic>> manualMaps,
  String ruleId,
  String date, {
  required bool removeGenerated,
}) {
  final rule = ruleById(store, ruleId);
  final occ = rule == null ? null : occurrenceOn(rule, date);
  if (rule == null || occ == null || occ['state'] != 'flagged') {
    return false;
  }
  if (removeGenerated) {
    final entryIdStored = occ['entryId']?.toString();
    if (entryIdStored != null) {
      manualMaps.removeWhere(
        (m) => entryId(manualTxnFromJson(m)) == entryIdStored,
      );
    }
    final cands = occ['flagCandidates'];
    if (cands is List && cands.isNotEmpty) {
      occ['captureKey'] = cands.first.toString();
    }
  }
  occ['state'] = 'resolved';
  occ['resolvedAt'] = DateTime.now().millisecondsSinceEpoch;
  occ.remove('flagReason');
  occ.remove('flagCandidates');
  return true;
}

/// User-confirmed posting of a flagged occurrence (credit guard
/// "Post it", or "Post instead" for an ambiguous match).
bool postFlaggedOccurrence(
  Map<String, dynamic> store,
  List<Map<String, dynamic>> manualMaps,
  String ruleId,
  String date,
  DateTime now,
) {
  final rule = ruleById(store, ruleId);
  final occ = rule == null ? null : occurrenceOn(rule, date);
  if (rule == null || occ == null || occ['state'] != 'flagged') {
    return false;
  }
  final dir = rule['dir'] == 'credit'
      ? TxnDirection.credit
      : TxnDirection.debit;
  final due = parseDateStr(date) ?? now;
  Bucket? bucket;
  for (final b in Bucket.values) {
    if (b.name == rule['bucket']) bucket = b;
  }
  final map = manualToJson(
    amount: rupeesFromPaise(_asInt(occ['amountPaise'], 0)),
    label: rule['label'] as String,
    at: DateTime(due.year, due.month, due.day, 12),
    direction: dir,
    note: rule['note']?.toString(),
    bucket: bucket,
    mode: rule['mode']?.toString(),
    origin: 'recurring',
    recurringId: ruleId,
    occurrenceDate: date,
    postedAtMs: now.millisecondsSinceEpoch,
  );
  // Id from the built map, exactly as the loader computes it.
  final id = entryId(manualTxnFromJson(map));
  occ['entryId'] = id;
  final exists = manualMaps.any(
    (m) => entryId(manualTxnFromJson(m)) == id,
  );
  if (!exists) manualMaps.add(map);
  occ['state'] = 'posted';
  occ.remove('flagReason');
  occ.remove('flagCandidates');
  rule['firedCount'] = _asInt(rule['firedCount'], 0) + 1;
  rule['lastFiredDate'] = date;
  return true;
}

/// User "Skip" on a flagged occurrence (credit guard / ambiguous
/// match). Skipped never consumes maxCount (spec §3.4).
bool skipFlaggedOccurrence(
  Map<String, dynamic> store,
  String ruleId,
  String date,
) {
  final rule = ruleById(store, ruleId);
  final occ = rule == null ? null : occurrenceOn(rule, date);
  if (rule == null || occ == null || occ['state'] != 'flagged') {
    return false;
  }
  occ['state'] = 'skipped';
  occ['resolvedAt'] = DateTime.now().millisecondsSinceEpoch;
  occ.remove('flagReason');
  occ.remove('flagCandidates');
  return true;
}

// ---------------------------------------------------------------------
// Pause / resume (spec §3.5)
// ---------------------------------------------------------------------

/// Pausing is immediate for un-fired dates: an open pause span
/// starts today; the engine records its due dates as skipped.
void pauseRule(Map<String, dynamic> rule, String today) {
  rule['status'] = 'paused';
  final spans = (rule['pauseSpans'] as List).cast<Map<String, dynamic>>();
  if (!spans.any((s) => s['to'] == null)) {
    spans.add({'from': today});
  }
}

/// Resuming closes the open pause span at yesterday — due dates
/// from today onward fire normally again; the span's dates stay
/// skipped forever (never caught up, decision #2).
void resumeRule(Map<String, dynamic> rule, String today) {
  rule['status'] = 'active';
  rule['restoredHold'] = false;
  final spans = (rule['pauseSpans'] as List).cast<Map<String, dynamic>>();
  for (final s in spans) {
    if (s['to'] == null) s['to'] = addDaysStr(today, -1);
  }
}

// ---------------------------------------------------------------------
// Restore hold (spec §6.2)
// ---------------------------------------------------------------------

/// Applied to a restored recurring document at import time (and to
/// the on-device document when a crashed restore is detected):
/// every rule is held (engine treats it as paused) and every
/// occurrence due before [restoreDate] is rewritten to `skipped`,
/// keeping entryId/captureKey. New due dates during the hold are
/// covered by the open pause span and recorded skipped by the
/// engine until the user resumes the rule.
Map<String, dynamic> applyRestoreHold(
  Map<String, dynamic> doc,
  String restoreDate,
) {
  final out = decodeRecurringStore(encodeRecurringStore(doc));
  for (final rule in rulesOf(out)) {
    rule['restoredHold'] = true;
    final spans = (rule['pauseSpans'] as List)
        .cast<Map<String, dynamic>>();
    if (!spans.any((s) => s['to'] == null)) {
      spans.add({'from': restoreDate});
    }
    for (final occ in occurrencesOf(rule)) {
      if ((occ['date'] as String).compareTo(restoreDate) < 0) {
        occ['state'] = 'skipped';
        occ.remove('flagReason');
        occ.remove('flagCandidates');
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------
// Possible refunds (spec §3.1) — informational only, never linked
// ---------------------------------------------------------------------

/// Captured credits that no occurrence consumed and whose
/// counterparty contains some rule's matchText — surfaced as
/// "Possible refund?" rows. Nothing is auto-linked (spec §3.7).
List<CaptureView> possibleRefunds(
  Map<String, dynamic> store,
  List<ParsedTransaction> captures,
) {
  final consumed = <String>{
    for (final r in rulesOf(store))
      for (final o in occurrencesOf(r))
        if (o['captureKey'] != null) o['captureKey'] as String,
  };
  final texts = <String>{
    for (final r in rulesOf(store))
      if ((r['matchText']?.toString() ?? '').trim().isNotEmpty)
        (r['matchText'] as String).trim().toLowerCase(),
  };
  if (texts.isEmpty) return const [];
  return [
    for (final t in captures)
      if (t.direction == TxnDirection.credit &&
          !consumed.contains(entryId(t)) &&
          t.counterparty != null &&
          texts.any((x) => t.counterparty!.toLowerCase().contains(x)))
        viewOf(t),
  ];
}
