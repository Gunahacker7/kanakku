/// Kanakku transaction parser.
///
/// Parses Indian bank / UPI transaction messages (SMS, app notifications,
/// email alerts) into structured transactions. Design rules:
///  - A message must carry a currency amount AND a debit/credit signal.
///  - OTP / verification / promo messages are ALWAYS rejected.
///  - Parsing is deterministic regex work that runs fully on-device.
library kanakku_parser;

enum TxnDirection { debit, credit }

enum TxnSource { sms, notification, email, manual, statement }

class ParsedTransaction {
  final double amount; // rupees, always positive
  final TxnDirection direction;
  final String? accountLast4;
  final double? balanceAfter; // rupees, if the message states it
  final String? counterparty; // merchant / payee raw text
  final String? bankHint; // guessed from sender or wording
  final String? upiRef;
  final TxnSource source;
  final DateTime receivedAt;
  final String rawBody;

  const ParsedTransaction({
    required this.amount,
    required this.direction,
    required this.source,
    required this.receivedAt,
    required this.rawBody,
    this.accountLast4,
    this.balanceAfter,
    this.counterparty,
    this.bankHint,
    this.upiRef,
  });

  /// Dedupe key: same spend arriving via SMS + notification + email
  /// collapses to one entry when amount + account + ref agree.
  String get dedupeKey =>
      '${amount.toStringAsFixed(2)}|${accountLast4 ?? ''}|${upiRef ?? ''}';

  @override
  String toString() =>
      'ParsedTransaction(${direction.name} ₹$amount, acct: $accountLast4, '
      'party: $counterparty, bal: $balanceAfter, bank: $bankHint, ref: $upiRef)';
}

class KanakkuParser {
  static final _otpSignals = RegExp(
    r'\b(otp|one[\s-]?time password|verification code|do not share|never share)\b',
    caseSensitive: false,
  );
  /// Card statement summaries ("Total Amt Due … Ignore if paid") are
  /// bills, not transactions — CardBillParser owns them. Without this
  /// guard the word "paid" in them reads as a debit verb and the total
  /// due would appear as a giant fake expense.
  static final _statementSignal = RegExp(
    r'\b(total|minimum|min\.?)\s*(amt|amount)?\s*due\b',
    caseSensitive: false,
  );
  static final _promoSignals = RegExp(
    r'\b(congratulations|you (have )?won|offer|discount|cashback offer|apply now|pre-?approved loan)\b',
    caseSensitive: false,
  );
  static final _currencyAmount = RegExp(
    r'(?:rs\.?|inr|₹)\s*[:\-]?\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );
  static final _amountBeforeVerb = RegExp(
    r'([\d,]+(?:\.\d{1,2})?)\s*(?:has been |is )?(?:debited|credited)',
    caseSensitive: false,
  );
  static final _debitVerbs = RegExp(
    r'\b(debited|spent|paid|withdrawn|purchase|deducted|sent to)\b',
    caseSensitive: false,
  );
  static final _creditVerbs = RegExp(
    r'\b(credited|received|deposited|refund(ed)?|added to)\b',
    caseSensitive: false,
  );
  static final _account = RegExp(
    r'(?:a/c|acct|account|card)\s*(?:no\.?\s*)?(?:ending\s*)?[x\*]*\s*(\d{3,4})\b',
    caseSensitive: false,
  );
  static final _balance = RegExp(
    r'(?:avl\.?\s*bal|available balance|bal(?:ance)?)[:\s]*(?:rs\.?|inr|₹)?\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );
  static final _upiRef = RegExp(
    r'(?:upi ref(?:\s*no)?|ref\s*no|utr)[:\s]*([0-9]{9,18})',
    caseSensitive: false,
  );
  static final _partyPatterns = <RegExp>[
    RegExp(r'info[:\s]*[a-z]+/([^/]+)/', caseSensitive: false), // ICICI Info: UPI/NAME/...
    RegExp(r'to\s+vpa\s+[\w.\-@]+\s*\(([^)]+)\)', caseSensitive: false),
    RegExp(r"\bat\s+([A-Za-z][A-Za-z0-9 .&'\-]{2,40}?)(?:\s+on\b|\s+via\b|\.)", caseSensitive: false),
    RegExp(r"\bto\s+([A-Za-z][A-Za-z0-9 .&'\-]{2,40}?)(?:\s+on\b|\s+via\b|\s+upi\b|\.)", caseSensitive: false),
    RegExp(r"\btowards\s+([A-Za-z][A-Za-z0-9 .&'\-]{2,40}?)(?:\s+on\b|\.)", caseSensitive: false),
  ];

  static final _bankBySender = <String, String>{
    'YESBANK': 'Yes Bank', 'YESBNK': 'Yes Bank',
    'SBI': 'SBI', 'HDFC': 'HDFC Bank', 'ICICI': 'ICICI Bank',
    'AXIS': 'Axis Bank', 'KOTAK': 'Kotak', 'INDBNK': 'Indian Bank',
    'CANARA': 'Canara Bank', 'PNB': 'PNB', 'BOB': 'Bank of Baroda',
    'IDFC': 'IDFC First', 'FEDERL': 'Federal Bank', 'IOB': 'IOB',
  };

  static double? _num(String? s) =>
      s == null ? null : double.tryParse(s.replaceAll(',', ''));

  /// Bank name guessed from an SMS sender id (e.g. "VM-HDFCBK" → HDFC Bank).
  /// Shared with the card-bill parser so both read senders the same way.
  static String? bankForSender(String sender) {
    final up = sender.toUpperCase();
    for (final e in _bankBySender.entries) {
      if (up.contains(e.key)) return e.value;
    }
    return null;
  }

  /// Last 3–4 digits of the account / card a message refers to.
  static String? accountLast4Of(String body) =>
      _account.firstMatch(body)?.group(1);

  /// Returns null when the message is not a financial transaction.
  static ParsedTransaction? parse(
    String body, {
    String sender = '',
    TxnSource source = TxnSource.sms,
    DateTime? receivedAt,
  }) {
    if (body.isEmpty) return null;
    if (_otpSignals.hasMatch(body)) return null;
    if (_statementSignal.hasMatch(body)) return null;
    if (_promoSignals.hasMatch(body) && !_debitVerbs.hasMatch(body) && !_creditVerbs.hasMatch(body)) {
      return null;
    }

    final isDebit = _debitVerbs.hasMatch(body);
    final isCredit = _creditVerbs.hasMatch(body);
    if (!isDebit && !isCredit) return null;
    // "debited ... credited" style balance summaries: first verb wins.
    final direction = (isDebit && isCredit)
        ? (body.toLowerCase().indexOf('debit') <
                body.toLowerCase().indexOf('credit')
            ? TxnDirection.debit
            : TxnDirection.credit)
        : (isDebit ? TxnDirection.debit : TxnDirection.credit);

    final amount = _num(_currencyAmount.firstMatch(body)?.group(1)) ??
        _num(_amountBeforeVerb.firstMatch(body)?.group(1));
    if (amount == null || amount <= 0) return null;

    String? party;
    for (final p in _partyPatterns) {
      final m = p.firstMatch(body);
      if (m != null) {
        party = m.group(1)?.trim();
        if (party != null && party.length >= 2) break;
        party = null;
      }
    }

    final bank = bankForSender(sender);

    return ParsedTransaction(
      amount: amount,
      direction: direction,
      accountLast4: _account.firstMatch(body)?.group(1),
      balanceAfter: _num(_balance.firstMatch(body)?.group(1)),
      counterparty: party,
      bankHint: bank,
      upiRef: _upiRef.firstMatch(body)?.group(1),
      source: source,
      receivedAt: receivedAt ?? DateTime.now(),
      rawBody: body,
    );
  }
}
