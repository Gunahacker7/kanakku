import 'dart:convert';

import 'package:flutter/services.dart'; // also brings in Uint8List
import 'package:kanakku_parser/kanakku_parser.dart';
import 'package:kanakku_parser/bills.dart';

/// Bridge to the Android capture layer (MainActivity + CaptureStore).
/// Every call is failure-safe: on non-Android platforms and in tests the
/// channel is absent and we simply report "no capture available".
class CaptureService {
  static const _ch = MethodChannel('in.kanakku/capture');

  Future<bool> hasSmsPermission() async {
    try {
      return await _ch.invokeMethod<bool>('hasSmsPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestSmsPermission() async {
    try {
      return await _ch.invokeMethod<bool>('requestSmsPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isNotificationAccessEnabled() async {
    try {
      return await _ch.invokeMethod<bool>('isNotificationAccessEnabled') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openNotificationSettings() async {
    try {
      await _ch.invokeMethod('openNotificationSettings');
    } catch (_) {}
  }

  /// All raw messages from the three channels, pre-parse.
  Future<List<({String sender, String body, int ts, TxnSource source})>>
  rawMessages() async {
    final out = <({String sender, String body, int ts, TxnSource source})>[];
    try {
      final inbox = await _ch.invokeMethod<List<dynamic>>('readSmsInbox', {
        'limit': 300,
      });
      for (final m in inbox ?? const []) {
        final map = Map<dynamic, dynamic>.from(m as Map);
        out.add((
          sender: map['sender']?.toString() ?? '',
          body: map['body']?.toString() ?? '',
          ts: (map['ts'] as num?)?.toInt() ?? 0,
          source: TxnSource.sms,
        ));
      }
    } catch (_) {}
    try {
      final smsJson = await _ch.invokeMethod<String>('getCapturedSms') ?? '[]';
      for (final m in jsonDecode(smsJson) as List<dynamic>) {
        final map = m as Map<String, dynamic>;
        out.add((
          sender: map['sender']?.toString() ?? '',
          body: map['body']?.toString() ?? '',
          ts: (map['ts'] as num?)?.toInt() ?? 0,
          source: TxnSource.sms,
        ));
      }
    } catch (_) {}
    try {
      final nJson =
          await _ch.invokeMethod<String>('getCapturedNotifications') ?? '[]';
      for (final m in jsonDecode(nJson) as List<dynamic>) {
        final map = m as Map<String, dynamic>;
        final title = map['title']?.toString() ?? '';
        final text = map['text']?.toString() ?? '';
        out.add((
          sender: map['pkg']?.toString() ?? '',
          body: title.isEmpty ? text : '$title $text',
          ts: (map['ts'] as num?)?.toInt() ?? 0,
          source: TxnSource.notification,
        ));
      }
    } catch (_) {}
    return out;
  }

  /// Parse + dedupe everything captured into transactions, newest first.
  Future<List<ParsedTransaction>> loadTransactions() async {
    final raw = await rawMessages();
    final byKey = <String, ParsedTransaction>{};
    for (final r in raw) {
      if (r.body.isEmpty) continue;
      final parsed = KanakkuParser.parse(
        r.body,
        sender: r.sender,
        source: r.source,
        receivedAt: r.ts > 0 ? DateTime.fromMillisecondsSinceEpoch(r.ts) : null,
      );
      if (parsed == null) continue;
      byKey.putIfAbsent(parsed.dedupeKey, () => parsed);
    }
    final list = byKey.values.toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return list;
  }

  /// Credit-card bills parsed from the same captured messages, deduped
  /// and ordered by due date (undated bills last, then most recent first).
  Future<List<CardBill>> loadBills() async {
    final raw = await rawMessages();
    final byKey = <String, CardBill>{};
    for (final r in raw) {
      if (r.body.isEmpty) continue;
      final bill = CardBillParser.parse(
        r.body,
        sender: r.sender,
        source: r.source,
        receivedAt: r.ts > 0 ? DateTime.fromMillisecondsSinceEpoch(r.ts) : null,
      );
      if (bill == null) continue;
      byKey.putIfAbsent(bill.dedupeKey, () => bill);
    }
    final list = byKey.values.toList()
      ..sort((a, b) {
        final ad = a.dueDate, bd = b.dueDate;
        if (ad != null && bd != null) return ad.compareTo(bd);
        if (ad != null) return -1;
        if (bd != null) return 1;
        return b.receivedAt.compareTo(a.receivedAt);
      });
    return list.take(10).toList();
  }

  /// Hands a CSV file to the Android share sheet via the native side.
  /// Returns the on-device path of the saved file, or '' when sharing
  /// is unavailable (non-Android, tests) — the UI then just confirms
  /// the export could not be shared.
  Future<String> shareCsv(String filename, String content) async {
    try {
      return await _ch.invokeMethod<String>('shareCsv', {
            'filename': filename,
            'content': content,
          }) ??
          '';
    } catch (_) {
      return '';
    }
  }

  Future<String> loadManualJson() async {
    try {
      return await _ch.invokeMethod<String>('getManual') ?? '[]';
    } catch (_) {
      return '[]';
    }
  }

  /// Persists the manual store. v1.0.1: returns the native side's
  /// real result (a synchronous SharedPreferences commit on a
  /// background thread) so a failed save can be surfaced — and the
  /// entry rolled back — instead of silently vanishing on restart.
  Future<bool> saveManualJson(String json) async {
    try {
      return await _ch.invokeMethod<bool>('setManual', {'json': json}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Transactions the user removed as spam/fake — filtered out on load,
  /// restorable from the Removed list.
  Future<String> loadRemovedJson() async {
    try {
      return await _ch.invokeMethod<String>('getRemoved') ?? '[]';
    } catch (_) {
      return '[]';
    }
  }

  Future<void> saveRemovedJson(String json) async {
    try {
      await _ch.invokeMethod('setRemoved', {'json': json});
    } catch (_) {}
  }

  /// Split bills (v0.5) — persisted natively like manual/removed.
  Future<String> loadSplitsJson() async {
    try {
      return await _ch.invokeMethod<String>('getSplits') ?? '[]';
    } catch (_) {
      return '[]';
    }
  }

  Future<void> saveSplitsJson(String json) async {
    try {
      await _ch.invokeMethod('setSplits', {'json': json});
    } catch (_) {}
  }

  /// User-edited monthly category budgets (v0.7), JSON map
  /// category → amount, persisted natively like the splits store.
  Future<String> loadBudgetsJson() async {
    try {
      return await _ch.invokeMethod<String>('getBudgets') ?? '{}';
    } catch (_) {
      return '{}';
    }
  }

  Future<void> saveBudgetsJson(String json) async {
    try {
      await _ch.invokeMethod('setBudgets', {'json': json});
    } catch (_) {}
  }

  /// Imported bank-statement transactions (v0.7), JSON list,
  /// persisted natively in their own store.
  Future<String> loadStatementJson() async {
    try {
      return await _ch.invokeMethod<String>('getStatement') ?? '[]';
    } catch (_) {
      return '[]';
    }
  }

  Future<void> saveStatementJson(String json) async {
    try {
      await _ch.invokeMethod('setStatement', {'json': json});
    } catch (_) {}
  }

  /// Opens the system document picker for a bank statement
  /// (CSV / PDF / text). Returns null when the user cancels or the
  /// picker is unavailable. [error] is set when a file was picked but
  /// could not be used ('too_large', 'unreadable', 'failed').
  Future<({String name, String mime, Uint8List? data, String? error})?>
  pickStatementFile() async {
    try {
      final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('pickFile');
      if (r == null) return null;
      return (
        name: r['name']?.toString() ?? '',
        mime: r['mime']?.toString() ?? '',
        data: r['data'] as Uint8List?,
        error: r['error']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Shares raw bytes (PDF export) through the same FileProvider
  /// share path as the CSV export. Returns the saved path or ''.
  Future<String> shareBytes(
    String filename,
    String mime,
    Uint8List bytes,
  ) async {
    try {
      return await _ch.invokeMethod<String>('shareBytes', {
            'filename': filename,
            'mime': mime,
            'data': base64Encode(bytes),
          }) ??
          '';
    } catch (_) {
      return '';
    }
  }

  /// Stores the daily-summary one-liner natively and (when [enabled])
  /// arms the daily alarm that posts it as a notification. [hour]/
  /// [minute] are the reminder time (v1.0 setting; default 21:00) —
  /// the native side persists it so the boot re-arm uses it too.
  Future<void> setDailySummary(
    String text,
    bool enabled, {
    int hour = 21,
    int minute = 0,
  }) async {
    try {
      await _ch.invokeMethod('setDailySummary', {
        'text': text,
        'enabled': enabled,
        'hour': hour,
        'minute': minute,
      });
    } catch (_) {}
  }

  /// App settings document (v1.0), one JSON string in its own store.
  Future<String> loadSettingsJson() async {
    try {
      return await _ch.invokeMethod<String>('getSettings') ?? '{}';
    } catch (_) {
      return '{}';
    }
  }

  Future<void> saveSettingsJson(String json) async {
    try {
      await _ch.invokeMethod('setSettings', {'json': json});
    } catch (_) {}
  }

  /// Personal categories + merchant rules (v1.0), one JSON document.
  Future<String> loadCategoriesJson() async {
    try {
      return await _ch.invokeMethod<String>('getCategories') ?? '{}';
    } catch (_) {
      return '{}';
    }
  }

  Future<void> saveCategoriesJson(String json) async {
    try {
      await _ch.invokeMethod('setCategories', {'json': json});
    } catch (_) {}
  }

  /// Recurring-rules document (v1.1, spec §2.1): one JSON string in
  /// its own native store. '' means the store was never written
  /// (pre-v1.1 install) — the migration and the defensive decoders
  /// treat that as the empty document.
  Future<String> loadRecurringJson() async {
    try {
      return await _ch.invokeMethod<String>('getRecurring') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Persists the recurring document with a synchronous native
  /// commit (like setManual): an engine pass must never report
  /// success for a write that did not land.
  Future<bool> saveRecurringJson(String json) async {
    try {
      return await _ch.invokeMethod<bool>('setRecurring', {'json': json}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Budget-alert state document (v1.1, spec §2.3). Device-local by
  /// design — never backed up. '' = never written.
  Future<String> loadAlertStateJson() async {
    try {
      return await _ch.invokeMethod<String>('getAlertState') ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> saveAlertStateJson(String json) async {
    try {
      await _ch.invokeMethod('setAlertState', {'json': json});
    } catch (_) {}
  }

  /// Posts a budget-alert notification natively (BudgetNotifier).
  /// Returns whether the notification was actually posted — the
  /// 2-per-day cap counts only real posts (spec §4.3 rule 2).
  Future<bool> postBudgetAlert(String title, String body) async {
    try {
      return await _ch.invokeMethod<bool>('postBudgetAlert', {
            'title': title,
            'body': body,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Biometric capability probe (v1.1, spec §5.2). Returns exactly
  /// one of: 'available', 'noneEnrolled', 'noHardware',
  /// 'noDeviceLock', 'unsupportedApi'. '' on channel failure —
  /// callers must treat anything but 'available' as "do not offer".
  Future<String> biometricStatus() async {
    try {
      return await _ch.invokeMethod<String>('biometricStatus') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Shows the framework biometric prompt (spec §5.2). True only on
  /// a real authentication success; cancel, lockout and every error
  /// return false (fail-closed, audit F13).
  Future<bool> biometricPrompt({
    String title = 'Unlock Kanakku',
    String subtitle = 'Use fingerprint or face',
  }) async {
    try {
      return await _ch.invokeMethod<bool>('biometricPrompt', {
            'title': title,
            'subtitle': subtitle,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Danger zone (v1.0): wipes EVERY native store (captured, manual,
  /// removed, splits, budgets, statement, settings, categories) and
  /// the PIN. Returns false when the platform side is unavailable.
  Future<bool> wipeAllData() async {
    try {
      return await _ch.invokeMethod<bool>('wipeAll') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the mail app addressed to [to] (Support "Query and
  /// Feedback" / "Contact Us"). False when no mail app answers.
  Future<bool> openMail(String to) async {
    try {
      return await _ch.invokeMethod<bool>('openMail', {'to': to}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Posts the summary notification immediately (test button).
  Future<bool> postSummaryNow(String text) async {
    try {
      return await _ch.invokeMethod<bool>('postSummaryNow', {'text': text}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestNotificationPermission() async {
    try {
      return await _ch.invokeMethod<bool>('requestNotificationPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// App-lock PIN (v0.5). The PIN is only ever handled natively,
  /// where it is stored as a salted PBKDF2 hash — never plaintext.
  Future<bool> pinIsSet() async {
    try {
      return await _ch.invokeMethod<bool>('pinIsSet') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Like [pinIsSet] but does NOT swallow channel failures: it
  /// throws when the platform side cannot answer. The app gate uses
  /// this so a slow/broken channel fails CLOSED (v1.0.4, audit F13)
  /// instead of silently opening the app.
  Future<bool> pinIsSetStrict() async =>
      await _ch.invokeMethod<bool>('pinIsSet') ?? false;

  Future<bool> pinSet(String pin) async {
    try {
      return await _ch.invokeMethod<bool>('pinSet', {'pin': pin}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The ONE counted verify (v1.0.4, audit F1): the native side
  /// counts the attempt against the shared failure counter and
  /// applies lockout backoff. Returns whether the PIN matched and,
  /// when it did not, how many seconds of lockout remain (0 = entry
  /// still allowed).
  Future<PinVerifyResult> pinVerify(String pin) async {
    try {
      final r = await _ch.invokeMethod<dynamic>('pinVerify', {'pin': pin});
      if (r is Map) {
        return PinVerifyResult(
          ok: r['ok'] == true,
          lockoutSeconds: (r['lockoutSeconds'] as num?)?.toInt() ?? 0,
        );
      }
      // Legacy/mock shape: a plain bool.
      return PinVerifyResult(ok: r == true, lockoutSeconds: 0);
    } catch (_) {
      return const PinVerifyResult(ok: false, lockoutSeconds: 0);
    }
  }

  /// Seconds of PIN lockout currently remaining (0 = none).
  Future<int> pinLockoutSecondsRemaining() async {
    try {
      return await _ch.invokeMethod<int>('pinLockout') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> pinClear() async {
    try {
      await _ch.invokeMethod('pinClear');
    } catch (_) {}
  }

  /// Passphrase-encrypts a backup document natively (PBKDF2 +
  /// AES-GCM, v1.0.4). Returns the Base64 blob for the backup
  /// envelope, or null when encryption is unavailable/failed.
  Future<String?> encryptBackup(String passphrase, String text) async {
    try {
      return await _ch.invokeMethod<String>('encryptBackup', {
        'passphrase': passphrase,
        'text': text,
      });
    } catch (_) {
      return null;
    }
  }

  /// Decrypts a backup blob from [encryptBackup]. Null means the
  /// passphrase was wrong (or the blob is damaged) — the caller
  /// must write nothing in that case.
  Future<String?> decryptBackup(String passphrase, String blob) async {
    try {
      return await _ch.invokeMethod<String>('decryptBackup', {
        'passphrase': passphrase,
        'data': blob,
      });
    } catch (_) {
      return null;
    }
  }
}

/// Outcome of the counted native PIN verify (v1.0.4).
class PinVerifyResult {
  final bool ok;

  /// Lockout seconds remaining after this attempt (0 = no lockout).
  final int lockoutSeconds;
  const PinVerifyResult({required this.ok, required this.lockoutSeconds});
}

/// One account's latest known balance (Walnut-style Accounts section).
class AccountBalance {
  final String bank; // display name, e.g. "HDFC Bank"
  final String last4;
  final double balance;
  final DateTime asOf; // timestamp of the newest SMS that stated it
  const AccountBalance({
    required this.bank,
    required this.last4,
    required this.balance,
    required this.asOf,
  });
  String get key => '$bank|$last4';
}

/// Latest balance per account: scans [txns] and keeps, per
/// (bank, last4), the balanceAfter from the NEWEST transaction whose
/// message stated one. Transactions without a stated balance never
/// erase a known one. Result is sorted by most recently updated.
List<AccountBalance> latestBalances(List<ParsedTransaction> txns) {
  final best = <String, AccountBalance>{};
  for (final t in txns) {
    final bal = t.balanceAfter;
    final last4 = t.accountLast4;
    if (bal == null || last4 == null) continue;
    final bank = t.bankHint ?? 'Account';
    final cand = AccountBalance(
      bank: bank,
      last4: last4,
      balance: bal,
      asOf: t.receivedAt,
    );
    final cur = best[cand.key];
    if (cur == null || cand.asOf.isAfter(cur.asOf)) best[cand.key] = cand;
  }
  return best.values.toList()..sort((a, b) => b.asOf.compareTo(a.asOf));
}
