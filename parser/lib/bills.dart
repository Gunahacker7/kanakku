/// Credit-card bill / due-date parser (Walnut parity, v0.4).
///
/// Card statement SMS look nothing like spend alerts: they carry a total
/// amount due, a minimum amount due and a payment due date, but no
/// debit/credit verb, so [KanakkuParser.parse] rightly returns null for
/// them. This parser turns them into [CardBill]s for the in-app Bills
/// section. Same rules as the transaction parser: OTP is always rejected,
/// everything is deterministic regex work on-device.
library kanakku_bills;

import 'kanakku_parser.dart';

class CardBill {
  final String? cardLast4;
  final String? bankHint;
  final double totalDue; // rupees
  final double? minDue; // rupees, if the message states it
  final DateTime? dueDate; // null when the SMS doesn't state one
  final DateTime receivedAt;
  final TxnSource source;
  final String rawBody;

  const CardBill({
    required this.totalDue,
    required this.receivedAt,
    required this.rawBody,
    this.cardLast4,
    this.bankHint,
    this.minDue,
    this.dueDate,
    this.source = TxnSource.sms,
  });

  /// One statement arriving via inbox + live capture + notification
  /// collapses to a single bill.
  String get dedupeKey =>
      '${cardLast4 ?? ''}|${totalDue.toStringAsFixed(2)}|'
      '${dueDate?.toIso8601String() ?? ''}';

  /// Whole days from [now] until the due date (negative = overdue).
  int? daysRemaining([DateTime? now]) {
    final d = dueDate;
    if (d == null) return null;
    final n = now ?? DateTime.now();
    final dueDay = DateTime(d.year, d.month, d.day);
    final today = DateTime(n.year, n.month, n.day);
    return dueDay.difference(today).inDays;
  }

  @override
  String toString() =>
      'CardBill($bankHint ••$cardLast4, total ₹$totalDue, min ₹$minDue, due $dueDate)';
}

class CardBillParser {
  static final _otpSignals = RegExp(
    r'\b(otp|one[\s-]?time password|verification code|do not share|never share)\b',
    caseSensitive: false,
  );

  /// A message is a bill only if it talks about an amount being DUE.
  static final _dueSignal = RegExp(
    r'\b(total\s+(amt|amount)|minimum\s+(amt|amount)|min\.?\s+(amt|amount)|amount\s+due|payment\s+due|due\s+date|due\s+by|amt\s+due|is\s+due)\b',
    caseSensitive: false,
  );

  static final _totalDue = <RegExp>[
    RegExp(
      r'total\s+(?:amt|amount)\s*due\s*(?:is)?\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*([\d,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
    RegExp(
      r'total\s*due\s*(?:amount)?\s*(?:is)?\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*([\d,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    ),
    RegExp(
      r'of\s+(?:rs\.?|inr|₹)\s*([\d,]+(?:\.\d{1,2})?)\s+is\s+due\b',
      caseSensitive: false,
    ),
    RegExp(
      r'(?:rs\.?|inr|₹)\s*([\d,]+(?:\.\d{1,2})?)\s+is\s+due\b',
      caseSensitive: false,
    ),
  ];

  static final _minDue = RegExp(
    r'min(?:imum)?\s*(?:amt|amount)?\s*due\s*(?:is)?\s*[:\-]?\s*(?:rs\.?|inr|₹)?\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  static final _dateAfterDue = RegExp(
    r'(?:due\s*(?:by|on|date)|pay\s*by|payment\s+due\s+date|on\s+or\s+before)'
    r'\s*[:\-]?\s*'
    r'(?:(\d{1,2})[\s\-]([a-z]{3,9})[\s\-]*(\d{4}|\d{2})?|(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4}|\d{2}))',
    caseSensitive: false,
  );
  static final _anyDate = RegExp(
    r'(?:(\d{1,2})[\s\-]([a-z]{3,9})[\s\-]*(\d{4}|\d{2})|(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4}))',
    caseSensitive: false,
  );

  static double? _num(String? s) =>
      s == null ? null : double.tryParse(s.replaceAll(',', ''));

  static DateTime? _decodeDate(RegExpMatch m, DateTime ref) {
    int day, month;
    int? year;
    if (m.group(1) != null) {
      day = int.parse(m.group(1)!);
      month = _months[m.group(2)!.substring(0, 3).toLowerCase()] ?? 0;
      if (month == 0) return null;
      final y = m.group(3);
      year = y == null ? null : (y.length == 2 ? 2000 + int.parse(y) : int.parse(y));
    } else {
      day = int.parse(m.group(4)!);
      month = int.parse(m.group(5)!);
      final y = m.group(6)!;
      year = y.length == 2 ? 2000 + int.parse(y) : int.parse(y);
      if (month < 1 || month > 12) return null;
    }
    if (day < 1 || day > 31) return null;
    var yr = year ?? ref.year;
    var dt = DateTime(yr, month, day);
    // No year stated and the date is well past: it's next year's bill.
    if (year == null && dt.isBefore(ref.subtract(const Duration(days: 60)))) {
      dt = DateTime(yr + 1, month, day);
    }
    return dt;
  }

  static DateTime? _dueDate(String body, DateTime ref) {
    final m = _dateAfterDue.firstMatch(body);
    if (m != null) return _decodeDate(m, ref);
    final a = _anyDate.firstMatch(body);
    if (a != null) return _decodeDate(a, ref);
    return null;
  }

  /// Returns null when the message is not a card bill / due notice.
  static CardBill? parse(
    String body, {
    String sender = '',
    TxnSource source = TxnSource.sms,
    DateTime? receivedAt,
  }) {
    if (body.isEmpty) return null;
    if (_otpSignals.hasMatch(body)) return null;
    if (!_dueSignal.hasMatch(body)) return null;

    double? total;
    for (final p in _totalDue) {
      total = _num(p.firstMatch(body)?.group(1));
      if (total != null) break;
    }
    if (total == null || total <= 0) return null;

    final at = receivedAt ?? DateTime.now();
    return CardBill(
      totalDue: total,
      minDue: _num(_minDue.firstMatch(body)?.group(1)),
      dueDate: _dueDate(body, at),
      cardLast4: KanakkuParser.accountLast4Of(body),
      bankHint: KanakkuParser.bankForSender(sender),
      source: source,
      receivedAt: at,
      rawBody: body,
    );
  }
}
