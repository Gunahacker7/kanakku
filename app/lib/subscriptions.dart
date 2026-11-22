/// Subscriptions module (v1.2, REDESIGN-SPEC §"Subscriptions
/// module"): the user's recurring paid services (Spotify, rent,
/// SIP…) as first-class records with a computed renewal engine.
///
/// Deliberately SEPARATE from lib/recurring.dart: recurring rules
/// are an expectation+reconciliation engine that posts real book
/// entries, while a subscription is a display/renewal record — it
/// never creates or modifies a transaction. The two share only the
/// date helpers (imported from recurring.dart) and the store
/// document conventions: one JSON document, defensive decode,
/// monotonic id sequence, dates as local 'yyyy-mm-dd' strings.
///
/// Money is integer paise (lib/money.dart is the only conversion
/// boundary). Total spent is COMPUTED from elapsed cycles; captured
/// transactions whose merchant matches are surfaced read-only by
/// the UI (see [SubPaymentView] / [matchedPayments]).
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'recurring.dart' show addDaysStr, dateStr, daysBetween, lastDayOfMonth, parseDateStr;

// ---------------------------------------------------------------------
// Store document
// ---------------------------------------------------------------------

const emptySubscriptionsStoreJson = '{"nextSubSeq":1,"subscriptions":[]}';

Map<String, dynamic> emptySubscriptionsStore() => {
  'nextSubSeq': 1,
  'subscriptions': <Map<String, dynamic>>[],
};

int _asInt(Object? v, int dflt) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? dflt : dflt);

String _asStr(Object? v, String dflt) {
  final s = v?.toString();
  return (s == null || s.isEmpty) ? dflt : s;
}

const subCycles = {'monthly', 'yearly', 'customDays'};

/// Subscription categories (the Add screen's chip row, spec §2).
const subCategories = <String>[
  'Entertainment',
  'Music',
  'Insurance',
  'Utilities',
  'Finance',
  'Health',
  'Other',
];

Map<String, dynamic> normalizeSubscription(Map<String, dynamic> s) {
  final cycle = s['cycle']?.toString();
  final status = s['status']?.toString();
  var customDays = _asInt(s['customDays'], 30);
  if (customDays < 1) customDays = 1;
  return {
    'id': _asStr(s['id'], ''),
    'name': _asStr(s['name'], ''),
    'brandKey': _asStr(s['brandKey'], 'custom'),
    'amountPaise': _asInt(s['amountPaise'], 0) < 0
        ? 0
        : _asInt(s['amountPaise'], 0),
    'cycle': subCycles.contains(cycle) ? cycle : 'monthly',
    'customDays': customDays,
    'firstBillingDate': _asStr(s['firstBillingDate'], ''),
    'category': _asStr(s['category'], 'Other'),
    'status': status == 'cancelled' ? 'cancelled' : 'active',
    if (s['cancelledDate'] != null &&
        s['cancelledDate'].toString().isNotEmpty)
      'cancelledDate': s['cancelledDate'].toString(),
    if (s['website'] != null && s['website'].toString().isNotEmpty)
      'website': s['website'].toString(),
    if (s['note'] != null && s['note'].toString().isNotEmpty)
      'note': s['note'].toString(),
    'createdAt': _asInt(s['createdAt'], 0),
    'updatedAt': _asInt(s['updatedAt'], 0),
  };
}

/// Defensive decode: malformed content degrades to the empty
/// document rather than throwing (same convention as the recurring
/// store, spec §2.1).
Map<String, dynamic> decodeSubscriptionsStore(String json) {
  try {
    final m = jsonDecode(json);
    if (m is Map) {
      final doc = Map<String, dynamic>.from(m);
      final subs = <Map<String, dynamic>>[];
      if (doc['subscriptions'] is List) {
        for (final s in doc['subscriptions'] as List) {
          if (s is Map) {
            subs.add(normalizeSubscription(Map<String, dynamic>.from(s)));
          }
        }
      }
      final seq = _asInt(doc['nextSubSeq'], 1);
      return {'nextSubSeq': seq < 1 ? 1 : seq, 'subscriptions': subs};
    }
  } catch (_) {}
  return emptySubscriptionsStore();
}

String encodeSubscriptionsStore(Map<String, dynamic> doc) => jsonEncode(doc);

List<Map<String, dynamic>> subscriptionsOf(Map<String, dynamic> doc) =>
    (doc['subscriptions'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic>? subscriptionById(Map<String, dynamic> doc, String id) {
  for (final s in subscriptionsOf(doc)) {
    if (s['id'] == id) return s;
  }
  return null;
}

/// Allocates a subscription id from the persisted monotonic
/// sequence — never derived from the list, so a delete can never
/// cause an id to be reused.
String newSubscriptionId(Map<String, dynamic> doc, int createdAtMs) {
  final seq = _asInt(doc['nextSubSeq'], 1);
  doc['nextSubSeq'] = seq + 1;
  return 'sub_${createdAtMs.toRadixString(36)}_$seq';
}

/// Builds a complete subscription map with defaults (used by the
/// add/edit form and by tests).
Map<String, dynamic> newSubscription({
  required String id,
  required String name,
  String brandKey = 'custom',
  required int amountPaise,
  String cycle = 'monthly',
  int customDays = 30,
  required String firstBillingDate,
  String category = 'Other',
  String? website,
  String? note,
  required int nowMs,
}) => normalizeSubscription({
  'id': id,
  'name': name,
  'brandKey': brandKey,
  'amountPaise': amountPaise,
  'cycle': cycle,
  'customDays': customDays,
  'firstBillingDate': firstBillingDate,
  'category': category,
  'website': ?website,
  'note': ?note,
  'status': 'active',
  'createdAt': nowMs,
  'updatedAt': nowMs,
});

// ---------------------------------------------------------------------
// Renewal engine — pure over yyyy-mm-dd strings
// ---------------------------------------------------------------------

/// Every billing date of [sub] in [fromInclusive, toInclusive],
/// ascending. Monthly/yearly stepping uses the NOMINAL day from
/// the first billing date, clamped to the month's last day — Jan 31
/// → Feb 28 → Mar 31, no drift (same rule as recurring §3.4).
List<String> subBillingDates(
  Map<String, dynamic> sub,
  String fromInclusive,
  String toInclusive,
) {
  final first = parseDateStr(sub['firstBillingDate']?.toString() ?? '');
  final from = parseDateStr(fromInclusive);
  final to = parseDateStr(toInclusive);
  if (first == null || to == null) return const [];
  if (first.isAfter(to)) return const [];
  final cycle = sub['cycle']?.toString() ?? 'monthly';
  final out = <String>[];
  void add(DateTime d) {
    if ((from == null || !d.isBefore(from)) && !d.isAfter(to)) {
      out.add(dateStr(d));
    }
  }

  if (cycle == 'customDays') {
    var step = _asInt(sub['customDays'], 30);
    if (step < 1) step = 1;
    var d = first;
    var guard = 0;
    while (!d.isAfter(to) && guard++ < 10000) {
      add(d);
      d = DateTime(d.year, d.month, d.day + step);
    }
  } else if (cycle == 'yearly') {
    var year = first.year;
    var guard = 0;
    while (guard++ < 1000) {
      final day = first.day <= lastDayOfMonth(year, first.month)
          ? first.day
          : lastDayOfMonth(year, first.month);
      final d = DateTime(year, first.month, day);
      if (d.isAfter(to)) break;
      add(d);
      year++;
    }
  } else {
    // monthly
    var monthIdx = first.year * 12 + (first.month - 1);
    final endIdx = to.year * 12 + (to.month - 1);
    var guard = 0;
    while (monthIdx <= endIdx && guard++ < 10000) {
      final y = monthIdx ~/ 12, m = monthIdx % 12 + 1;
      final day = first.day <= lastDayOfMonth(y, m)
          ? first.day
          : lastDayOfMonth(y, m);
      add(DateTime(y, m, day));
      monthIdx++;
    }
  }
  return out;
}

/// The billing date one cycle BEFORE [date] (which must itself be
/// a billing date of [sub]) — used only to size the very first
/// cycle for the progress bar before any bill has landed.
String _previousBillingDate(Map<String, dynamic> sub, String date) {
  final d = parseDateStr(date);
  if (d == null) return date;
  final cycle = sub['cycle']?.toString() ?? 'monthly';
  if (cycle == 'customDays') {
    var step = _asInt(sub['customDays'], 30);
    if (step < 1) step = 1;
    return dateStr(DateTime(d.year, d.month, d.day - step));
  }
  if (cycle == 'yearly') {
    final y = d.year - 1;
    final day = d.day <= lastDayOfMonth(y, d.month)
        ? d.day
        : lastDayOfMonth(y, d.month);
    return dateStr(DateTime(y, d.month, day));
  }
  final idx = d.year * 12 + (d.month - 1) - 1;
  final y = idx ~/ 12, m = idx % 12 + 1;
  final first = parseDateStr(sub['firstBillingDate']?.toString() ?? '');
  final nominal = first?.day ?? d.day;
  final day = nominal <= lastDayOfMonth(y, m) ? nominal : lastDayOfMonth(y, m);
  return dateStr(DateTime(y, m, day));
}

/// Billing dates that have actually landed by [today]: from the
/// first billing date up to today, and never past the cancellation
/// date of a cancelled subscription.
List<String> elapsedBillingDates(Map<String, dynamic> sub, String today) {
  var end = today;
  final cancelled = sub['cancelledDate']?.toString();
  if (cancelled != null && cancelled.isNotEmpty && cancelled.compareTo(end) < 0) {
    end = cancelled;
  }
  final first = sub['firstBillingDate']?.toString() ?? '';
  if (first.isEmpty || first.compareTo(end) > 0) return const [];
  return subBillingDates(sub, first, end);
}

/// The next renewal date strictly after [today] — a bill landing
/// today already counts as billed (it is in [elapsedBillingDates]).
/// Null for cancelled subscriptions: cancellation stops all future
/// renewals.
String? nextRenewalDate(Map<String, dynamic> sub, String today) {
  if (sub['status'] == 'cancelled') return null;
  final first = sub['firstBillingDate']?.toString() ?? '';
  if (first.isEmpty) return null;
  if (first.compareTo(today) > 0) return first;
  final dates = subBillingDates(sub, first, addDaysStr(today, 400));
  for (final d in dates) {
    if (d.compareTo(today) > 0) return d;
  }
  // Long custom cycles can step past the 400-day scan window.
  var horizon = addDaysStr(today, 400);
  for (var i = 0; i < 40; i++) {
    horizon = addDaysStr(horizon, 400);
    final more = subBillingDates(sub, first, horizon);
    for (final d in more) {
      if (d.compareTo(today) > 0) return d;
    }
  }
  return null;
}

/// Cycle progress for the details screen (reference 05: "Day 9 of
/// 30" over a green bar). The current cycle runs from the last
/// billed date to the next billing date; before the first bill, a
/// virtual previous cycle of the same length is assumed so the bar
/// still reads sensibly. [fraction] is the elapsed share 0..1.
({String? lastBilled, String? next, int dayX, int dayY, double fraction})
cycleProgress(Map<String, dynamic> sub, String today) {
  final elapsed = elapsedBillingDates(sub, today);
  final lastBilled = elapsed.isEmpty ? null : elapsed.last;
  // Next billing after the current cycle start — computed even for
  // cancelled subs (the bar freezes at cancellation); the UI uses
  // nextRenewalDate for anything user-facing about the future.
  String? next;
  final anchor = lastBilled ?? sub['firstBillingDate']?.toString() ?? '';
  if (anchor.isNotEmpty) {
    if (lastBilled == null) {
      next = anchor; // the first billing itself
    } else {
      final dates = subBillingDates(
        sub,
        anchor,
        addDaysStr(anchor, 5000),
      );
      for (final d in dates) {
        if (d.compareTo(anchor) > 0) {
          next = d;
          break;
        }
      }
    }
  }
  if (next == null) {
    return (lastBilled: lastBilled, next: null, dayX: 0, dayY: 0, fraction: 0);
  }
  final start = lastBilled ?? _previousBillingDate(sub, next);
  final dayY = daysBetween(start, next);
  // A cancelled subscription's bar freezes at the cancel date.
  var effectiveToday = today;
  final cancelled = sub['cancelledDate']?.toString();
  if (sub['status'] == 'cancelled' &&
      cancelled != null &&
      cancelled.isNotEmpty &&
      cancelled.compareTo(effectiveToday) < 0) {
    effectiveToday = cancelled;
  }
  final elapsedDays = daysBetween(start, effectiveToday);
  final dayX = elapsedDays + 1;
  return (
    lastBilled: lastBilled,
    next: next,
    dayX: dayX < 0 ? 0 : dayX,
    dayY: dayY < 0 ? 0 : dayY,
    fraction: dayY <= 0
        ? 0
        : (elapsedDays / dayY).clamp(0, 1).toDouble(),
  );
}

/// Total spent = amount × elapsed cycles (computed, per spec —
/// matched captures are displayed separately, never summed in).
int totalSpentPaise(Map<String, dynamic> sub, String today) =>
    _asInt(sub['amountPaise'], 0) * elapsedBillingDates(sub, today).length;

/// Renewals of [sub] inside [fromInclusive, toInclusive] for
/// calendar/upcoming views: past renewals count even for cancelled
/// subs (they happened), future ones only while active, and never
/// past the cancellation date.
List<String> renewalsInRange(
  Map<String, dynamic> sub,
  String fromInclusive,
  String toInclusive,
  String today,
) {
  final first = sub['firstBillingDate']?.toString() ?? '';
  if (first.isEmpty) return const [];
  final cancelled = sub['cancelledDate']?.toString();
  return [
    for (final d in subBillingDates(sub, fromInclusive, toInclusive))
      if ((sub['status'] != 'cancelled' || d.compareTo(today) <= 0) &&
          (cancelled == null || cancelled.isEmpty || d.compareTo(cancelled) <= 0))
        d,
  ];
}

/// Sum of renewal amounts falling due in [today, today + days]
/// (both ends inclusive) across ACTIVE subscriptions.
({int count, int totalPaise}) dueWithin(
  Map<String, dynamic> doc,
  String today,
  int days,
) {
  final to = addDaysStr(today, days);
  var count = 0, total = 0;
  for (final sub in subscriptionsOf(doc)) {
    if (sub['status'] == 'cancelled') continue;
    final dates = subBillingDates(sub, today, to);
    count += dates.length;
    total += dates.length * _asInt(sub['amountPaise'], 0);
  }
  return (count: count, totalPaise: total);
}

/// One upcoming renewal: the subscription + its next date.
class UpcomingRenewal {
  final Map<String, dynamic> sub;
  final String date;
  const UpcomingRenewal(this.sub, this.date);
}

/// Active subscriptions with a future renewal, soonest first
/// (name breaks ties), optionally truncated to [limit].
List<UpcomingRenewal> upcomingRenewals(
  Map<String, dynamic> doc,
  String today, {
  int? limit,
}) {
  final out = <UpcomingRenewal>[];
  for (final sub in subscriptionsOf(doc)) {
    final next = nextRenewalDate(sub, today);
    if (next != null) out.add(UpcomingRenewal(sub, next));
  }
  out.sort((a, b) {
    final c = a.date.compareTo(b.date);
    return c != 0
        ? c
        : (a.sub['name'] as String).compareTo(b.sub['name'] as String);
  });
  return limit == null ? out : out.take(limit).toList();
}

// ---------------------------------------------------------------------
// Labels / formatting
// ---------------------------------------------------------------------

const subMonthNames = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const subMonthAbbr = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// 'Dec 1, 2026' (reference style) for a yyyy-mm-dd string.
String fmtSubDate(String date) {
  final d = parseDateStr(date);
  if (d == null) return date;
  return '${subMonthAbbr[d.month - 1]} ${d.day}, ${d.year}';
}

String cycleLabel(Map<String, dynamic> sub) {
  final cycle = sub['cycle']?.toString() ?? 'monthly';
  if (cycle == 'yearly') return 'Yearly';
  if (cycle == 'customDays') {
    final n = _asInt(sub['customDays'], 30);
    return n == 1 ? 'Daily' : 'Every $n days';
  }
  return 'Monthly';
}

/// The list-row sub-line (reference 02): "Renews tomorrow",
/// "Renews on Dec 1, 2026", "Starts on …" before the first bill,
/// "Cancelled" once cancelled.
String renewsLabel(Map<String, dynamic> sub, String today) {
  if (sub['status'] == 'cancelled') return 'Cancelled';
  final next = nextRenewalDate(sub, today);
  if (next == null) return '';
  if (elapsedBillingDates(sub, today).isEmpty) {
    return 'Starts on ${fmtSubDate(next)}';
  }
  if (next == addDaysStr(today, 1)) return 'Renews tomorrow';
  return 'Renews on ${fmtSubDate(next)}';
}

// ---------------------------------------------------------------------
// Brand / essentials catalog — simple tinted letter/icon tiles,
// drawn in code (NO external brand image assets, per spec).
// ---------------------------------------------------------------------

class SubBrand {
  final String key;
  final String name;
  final String category;
  final Color tint;
  final Color fg;
  final IconData icon;

  /// Lowercase fragments matched against captured-transaction
  /// counterparties for the read-only "paid via captures" link.
  final List<String> matchKeys;
  const SubBrand({
    required this.key,
    required this.name,
    required this.category,
    required this.tint,
    required this.fg,
    required this.icon,
    this.matchKeys = const [],
  });

  String get initials {
    final words = name
        .replaceAll(RegExp(r'[^A-Za-z0-9 ]'), '')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      final w = words.first;
      return w.length <= 2 ? w.toUpperCase() : w[0].toUpperCase();
    }
    return (words[0][0] + words[1][0]).toUpperCase();
  }
}

/// "Essentials" grid (reference 03): everyday recurring payments.
const essentialBrands = <SubBrand>[
  SubBrand(
    key: 'gym',
    name: 'Gym',
    category: 'Health',
    tint: Color(0xFFE2F2E6),
    fg: Color(0xFF1E7A46),
    icon: Icons.fitness_center,
    matchKeys: ['gym', 'fitness', 'cult'],
  ),
  SubBrand(
    key: 'wifi',
    name: 'Wi-Fi',
    category: 'Utilities',
    tint: Color(0xFFE1EDFA),
    fg: Color(0xFF2563EB),
    icon: Icons.wifi,
    matchKeys: ['broadband', 'fiber', 'fibernet'],
  ),
  SubBrand(
    key: 'emi',
    name: 'EMI',
    category: 'Finance',
    tint: Color(0xFFF8ECD2),
    fg: Color(0xFF96690F),
    icon: Icons.account_balance,
    matchKeys: ['emi'],
  ),
  SubBrand(
    key: 'sip',
    name: 'SIP',
    category: 'Finance',
    tint: Color(0xFFDFF2E4),
    fg: Color(0xFF1E6B4F),
    icon: Icons.trending_up,
    matchKeys: ['sip', 'mutual fund', 'zerodha', 'groww'],
  ),
  SubBrand(
    key: 'rent',
    name: 'Rent',
    category: 'Utilities',
    tint: Color(0xFFFBE7DA),
    fg: Color(0xFFB45309),
    icon: Icons.home,
    matchKeys: ['rent'],
  ),
  SubBrand(
    key: 'fee',
    name: 'Fee',
    category: 'Other',
    tint: Color(0xFFF3E8FD),
    fg: Color(0xFF7C3AED),
    icon: Icons.school,
    matchKeys: ['fee', 'school', 'tuition'],
  ),
  SubBrand(
    key: 'tvdth',
    name: 'TV / DTH',
    category: 'Entertainment',
    tint: Color(0xFFF3E8FD),
    fg: Color(0xFF7C3AED),
    icon: Icons.tv,
    matchKeys: ['dth', 'tata play', 'dish tv', 'sun direct'],
  ),
  SubBrand(
    key: 'mobile',
    name: 'Mobile Plan',
    category: 'Utilities',
    tint: Color(0xFFE4E7FB),
    fg: Color(0xFF4338CA),
    icon: Icons.smartphone,
    matchKeys: ['recharge', 'prepaid'],
  ),
  SubBrand(
    key: 'puc',
    name: 'PUC',
    category: 'Other',
    tint: Color(0xFFFBE4E4),
    fg: Color(0xFFC13B3B),
    icon: Icons.directions_car,
    matchKeys: ['puc', 'pollution'],
  ),
  SubBrand(
    key: 'electricity',
    name: 'Electricity',
    category: 'Utilities',
    tint: Color(0xFFFBF0CD),
    fg: Color(0xFF96690F),
    icon: Icons.bolt,
    matchKeys: ['electricity', 'tneb', 'bescom', 'power bill'],
  ),
  SubBrand(
    key: 'gas',
    name: 'Gas',
    category: 'Utilities',
    tint: Color(0xFFFBE7DA),
    fg: Color(0xFFC2410C),
    icon: Icons.local_fire_department,
    matchKeys: ['gas', 'lpg', 'indane', 'hp gas', 'bharat gas'],
  ),
  SubBrand(
    key: 'water',
    name: 'Water',
    category: 'Utilities',
    tint: Color(0xFFDFF3FB),
    fg: Color(0xFF0277BD),
    icon: Icons.water_drop,
    matchKeys: ['water bill', 'metro water'],
  ),
];

/// "Popular" grid (reference 03): well-known subscription brands.
const popularBrands = <SubBrand>[
  SubBrand(
    key: 'spotify',
    name: 'Spotify',
    category: 'Music',
    tint: Color(0xFFDFF5E3),
    fg: Color(0xFF1DB954),
    icon: Icons.music_note,
    matchKeys: ['spotify'],
  ),
  SubBrand(
    key: 'youtube',
    name: 'YouTube Premium',
    category: 'Entertainment',
    tint: Color(0xFFFDE7E7),
    fg: Color(0xFFFF0000),
    icon: Icons.smart_display,
    matchKeys: ['youtube'],
  ),
  SubBrand(
    key: 'netflix',
    name: 'Netflix',
    category: 'Entertainment',
    tint: Color(0xFFFBE4E4),
    fg: Color(0xFFE50914),
    icon: Icons.movie,
    matchKeys: ['netflix'],
  ),
  SubBrand(
    key: 'primevideo',
    name: 'Prime Video',
    category: 'Entertainment',
    tint: Color(0xFFDFF0FB),
    fg: Color(0xFF00A8E1),
    icon: Icons.play_circle_fill,
    matchKeys: ['prime video', 'primevideo', 'amazon prime'],
  ),
  SubBrand(
    key: 'icloud',
    name: 'Apple iCloud',
    category: 'Utilities',
    tint: Color(0xFFE3F0FB),
    fg: Color(0xFF0B84FF),
    icon: Icons.cloud,
    matchKeys: ['icloud'],
  ),
  SubBrand(
    key: 'applemusic',
    name: 'Apple Music',
    category: 'Music',
    tint: Color(0xFFFBE7EF),
    fg: Color(0xFFFA2D48),
    icon: Icons.library_music,
    matchKeys: ['apple music'],
  ),
  SubBrand(
    key: 'airtel',
    name: 'Airtel',
    category: 'Utilities',
    tint: Color(0xFFFBE4E4),
    fg: Color(0xFFED1C24),
    icon: Icons.sim_card,
    matchKeys: ['airtel'],
  ),
  SubBrand(
    key: 'jiohotstar',
    name: 'Jio Hotstar',
    category: 'Entertainment',
    tint: Color(0xFFE4E7FB),
    fg: Color(0xFF3D5AFE),
    icon: Icons.live_tv,
    matchKeys: ['hotstar', 'jio'],
  ),
  SubBrand(
    key: 'canva',
    name: 'Canva',
    category: 'Other',
    tint: Color(0xFFE4F6F8),
    fg: Color(0xFF00C4CC),
    icon: Icons.brush,
    matchKeys: ['canva'],
  ),
  SubBrand(
    key: 'chatgpt',
    name: 'ChatGPT',
    category: 'Other',
    tint: Color(0xFFE2F2EE),
    fg: Color(0xFF10A37F),
    icon: Icons.smart_toy,
    matchKeys: ['chatgpt', 'openai'],
  ),
  SubBrand(
    key: 'claude',
    name: 'Claude',
    category: 'Other',
    tint: Color(0xFFFBEEDD),
    fg: Color(0xFFD97757),
    icon: Icons.auto_awesome,
    matchKeys: ['claude', 'anthropic'],
  ),
  SubBrand(
    key: 'duolingo',
    name: 'Duolingo',
    category: 'Other',
    tint: Color(0xFFE6F7DC),
    fg: Color(0xFF58CC02),
    icon: Icons.translate,
    matchKeys: ['duolingo'],
  ),
  SubBrand(
    key: 'hbo',
    name: 'HBO',
    category: 'Entertainment',
    tint: Color(0xFFE8E8EE),
    fg: Color(0xFF1C1E1C),
    icon: Icons.movie_filter,
    matchKeys: ['hbo'],
  ),
  SubBrand(
    key: 'onepassword',
    name: '1Password',
    category: 'Utilities',
    tint: Color(0xFFE1EDFA),
    fg: Color(0xFF1B285F),
    icon: Icons.lock,
    matchKeys: ['1password'],
  ),
  SubBrand(
    key: 'blinkist',
    name: 'Blinkist',
    category: 'Other',
    tint: Color(0xFFDFF5EA),
    fg: Color(0xFF00C29A),
    icon: Icons.menu_book,
    matchKeys: ['blinkist'],
  ),
  SubBrand(
    key: 'snapchat',
    name: 'Snapchat',
    category: 'Entertainment',
    tint: Color(0xFFFBF6CD),
    fg: Color(0xFFB7A600),
    icon: Icons.camera_alt,
    matchKeys: ['snapchat'],
  ),
];

final _brandByKey = <String, SubBrand>{
  for (final b in [...essentialBrands, ...popularBrands]) b.key: b,
};

/// The catalog brand for [key]; unknown keys (custom entries) get
/// a neutral tile keyed off the subscription's own name.
SubBrand brandFor(String key, {String fallbackName = ''}) =>
    _brandByKey[key] ??
    SubBrand(
      key: 'custom',
      name: fallbackName,
      category: 'Other',
      tint: const Color(0xFFEDEDE8),
      fg: const Color(0xFF6F7268),
      icon: Icons.subscriptions,
    );

// ---------------------------------------------------------------------
// Auto-capture link (light, read-only)
// ---------------------------------------------------------------------

/// One captured/manual debit as the subscription screens see it —
/// a plain view built by the Shell from its entries. Display only:
/// nothing here ever creates or modifies a transaction.
class SubPaymentView {
  final String name; // counterparty / label
  final int amountPaise;
  final String date; // yyyy-mm-dd
  const SubPaymentView({
    required this.name,
    required this.amountPaise,
    required this.date,
  });
}

/// True when a captured payment plausibly belongs to [sub]: the
/// counterparty contains the subscription's name, its brand name,
/// or one of the brand's match fragments (case-insensitive).
bool paymentMatchesSub(Map<String, dynamic> sub, SubPaymentView p) {
  final party = p.name.toLowerCase();
  if (party.isEmpty) return false;
  final brand = brandFor(
    sub['brandKey']?.toString() ?? 'custom',
    fallbackName: sub['name']?.toString() ?? '',
  );
  final keys = <String>{
    (sub['name']?.toString() ?? '').toLowerCase(),
    brand.name.toLowerCase(),
    ...brand.matchKeys,
  };
  return keys.any((k) => k.isNotEmpty && party.contains(k));
}

/// Captured payments matching [sub], newest first.
List<SubPaymentView> matchedPayments(
  Map<String, dynamic> sub,
  List<SubPaymentView> payments,
) => [
  for (final p in payments)
    if (paymentMatchesSub(sub, p)) p,
]..sort((a, b) => b.date.compareTo(a.date));

// ---------------------------------------------------------------------
// Renewal reminders — evaluated on app open, exactly like the
// budget alerts (spec §4.1 pattern): the evaluation is pure and
// deduped through the alert-state document; the Shell posts via
// the existing immediate-notification channel. (OS-level scheduled
// alarms would need new native plumbing — Phase 3.)
// ---------------------------------------------------------------------

/// Alert-state key holding {subId: lastRemindedRenewalDate}.
const subRemindersAlertKey = 'subReminders';

/// Subscriptions whose next renewal is TOMORROW and that have not
/// yet been reminded for that renewal date.
List<UpcomingRenewal> pendingRenewalReminders(
  Map<String, dynamic> doc,
  Map<String, dynamic> alertState,
  String today,
) {
  final tomorrow = addDaysStr(today, 1);
  final raw = alertState[subRemindersAlertKey];
  final reminded = raw is Map
      ? raw.map((k, v) => MapEntry(k.toString(), v.toString()))
      : const <String, String>{};
  return [
    for (final u in upcomingRenewals(doc, today))
      if (u.date == tomorrow && reminded[u.sub['id']] != u.date) u,
  ];
}

/// Records that [subId]'s renewal on [date] has been reminded, so
/// the same renewal never notifies twice.
void markRenewalReminded(
  Map<String, dynamic> alertState,
  String subId,
  String date,
) {
  final raw = alertState[subRemindersAlertKey];
  final m = raw is Map
      ? Map<String, dynamic>.from(raw)
      : <String, dynamic>{};
  m[subId] = date;
  alertState[subRemindersAlertKey] = m;
}
