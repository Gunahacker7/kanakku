import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanakku_parser/kanakku_parser.dart';
import 'package:kanakku_parser/bills.dart';
import 'package:kanakku_parser/categorize.dart';

import 'backup.dart';
import 'budget_alerts.dart';
import 'budgets.dart';
import 'capture.dart';
import 'categories.dart';
import 'csv_export.dart';
import 'insights_data.dart';
import 'manual.dart';
import 'money.dart';
import 'pdf_export.dart';
import 'pin.dart';
import 'recurring.dart';
import 'settings.dart';
import 'splits.dart';
import 'statement.dart';
import 'summary.dart';
import 'theme.dart';

void main() => runApp(const KanakkuApp());

/// App root. v1.0: holds the Appearance setting (Light/Dark/Device)
/// reported up by the Shell once the settings document loads; the
/// effective brightness is pushed into [KanakkuTheme] so every
/// surface colour follows.
class KanakkuApp extends StatefulWidget {
  const KanakkuApp({super.key});
  @override
  State<KanakkuApp> createState() => _KanakkuAppState();
}

class _KanakkuAppState extends State<KanakkuApp> {
  String _themePref = 'device';

  void _onThemePref(String pref) {
    if (pref != _themePref) setState(() => _themePref = pref);
  }

  @override
  Widget build(BuildContext context) {
    final platformDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final dark =
        _themePref == 'dark' || (_themePref == 'device' && platformDark);
    KanakkuTheme.applyAppearance(dark);
    return MaterialApp(
      title: 'Kanakku',
      debugShowCheckedModeBanner: false,
      theme: KanakkuTheme.light(),
      darkTheme: KanakkuTheme.dark(),
      themeMode: _themePref == 'dark'
          ? ThemeMode.dark
          : _themePref == 'light'
          ? ThemeMode.light
          : ThemeMode.system,
      home: _AppGate(onThemePref: _onThemePref),
    );
  }
}

/// App lock gate (v0.5): when a PIN is set natively, the lock screen
/// comes before any data — at launch, and again after the app has
/// spent more than a minute in the background.
class _AppGate extends StatefulWidget {
  final void Function(String) onThemePref;
  const _AppGate({required this.onThemePref});
  @override
  State<_AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<_AppGate> with WidgetsBindingObserver {
  final _capture = CaptureService();
  bool _checking = true;
  bool _checkFailed = false;
  bool _pinSet = false;
  bool _locked = false;

  /// v1.1 (spec §5.4): the settings flag, loaded at gate time. The
  /// lock screen additionally requires a live 'available' probe
  /// before offering biometrics, and never while a PIN lockout runs.
  bool _biometricUnlock = false;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _check() async {
    // v1.0.4 (audit F13): the gate fails CLOSED. Previously a slow
    // platform channel (2 s timeout) was treated as "no PIN set"
    // and the app opened unlocked; now an unanswered check keeps
    // the app locked behind a retry affordance. Only an answered
    // "no PIN" opens the shell.
    setState(() {
      _checking = true;
      _checkFailed = false;
    });
    // v1.1 migration (spec §6.1), Dart half: seed the two new
    // documents when absent. Idempotent — the native migration in
    // CaptureStore does the same under the migrated_v110 flag, and
    // an existing document is never rewritten here.
    try {
      if ((await _capture.loadRecurringJson()).isEmpty) {
        await _capture.saveRecurringJson(emptyRecurringStoreJson);
      }
      if ((await _capture.loadAlertStateJson()).isEmpty) {
        await _capture.saveAlertStateJson('{}');
      }
    } catch (_) {}
    try {
      final set = await _capture
          .pinIsSetStrict()
          .timeout(const Duration(seconds: 5));
      var bio = false;
      if (set) {
        try {
          bio = decodeSettings(
            await _capture.loadSettingsJson(),
          ).biometricUnlock;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _pinSet = set;
        _locked = set;
        _biometricUnlock = bio;
        _checking = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkFailed = true;
        _locked = true; // stay shut until the check can be answered
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed && _pinSet && !_locked) {
      final at = _pausedAt;
      if (at != null && DateTime.now().difference(at).inSeconds > 60) {
        setState(() => _locked = true);
      }
      _pausedAt = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_checkFailed) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 44,
                  color: KanakkuTheme.orange,
                ),
                const SizedBox(height: 12),
                Text('Kanakku is locked', style: KanakkuTheme.serif(size: 22)),
                const SizedBox(height: 4),
                Text(
                  'The app lock could not be verified just now, so '
                  'Kanakku stays locked.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: KanakkuTheme.inkSoft),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: KanakkuTheme.orange,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 14,
                    ),
                  ),
                  onPressed: _check,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_locked) {
      return _LockScreen(
        capture: _capture,
        biometricUnlock: _biometricUnlock,
        onUnlocked: () => setState(() => _locked = false),
      );
    }
    return Shell(onThemePref: widget.onThemePref);
  }
}

/// Numeric PIN entry. Attempts are counted natively (shared with
/// every other PIN prompt); after [pinMaxFailures] wrong PINs a
/// growing lockout applies and this screen shows the wait. There
/// is deliberately NO reset escape hatch here (v1.0.4, audit F1) —
/// the PIN can only be changed or disabled from Settings, after a
/// successful unlock.
class _LockScreen extends StatefulWidget {
  final CaptureService capture;
  final VoidCallback onUnlocked;

  /// v1.1 (spec §5.4): the Settings toggle. Biometrics are offered
  /// only when this is on AND a PIN is set (guaranteed by the gate)
  /// AND the live probe says 'available' AND no lockout is running.
  final bool biometricUnlock;
  const _LockScreen({
    required this.capture,
    required this.onUnlocked,
    this.biometricUnlock = false,
  });
  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  /// Seconds of native lockout left; ticks down once a second.
  int _lockoutLeft = 0;
  Timer? _ticker;

  /// v1.1: last biometric probe result; null until probed.
  String? _bioStatus;
  bool _bioPrompted = false;

  @override
  void initState() {
    super.initState();
    _refreshLockout();
    _probeBiometrics();
  }

  /// Probes capability once per lock-screen appearance and, when
  /// biometrics are usable, auto-prompts exactly once (spec §5.4).
  /// NEVER prompts while a PIN lockout runs (decision #4): the
  /// probe result is still recorded so the retry button can appear
  /// the moment the lockout expires.
  Future<void> _probeBiometrics() async {
    if (!widget.biometricUnlock) return;
    final status = await widget.capture.biometricStatus();
    if (!mounted) return;
    setState(() => _bioStatus = status);
    if (status != 'available' || _bioPrompted) return;
    final left = await widget.capture.pinLockoutSecondsRemaining();
    if (!mounted || left > 0) return;
    _bioPrompted = true;
    await _promptBiometric();
  }

  Future<void> _promptBiometric() async {
    // Decision #4: Dart must not invoke the prompt while the PIN
    // lockout is active.
    if (_lockoutLeft > 0) return;
    final left = await widget.capture.pinLockoutSecondsRemaining();
    if (!mounted || left > 0) return;
    final ok = await widget.capture.biometricPrompt();
    if (!mounted) return;
    if (ok) {
      // A lockout could have begun while the prompt was up (failed
      // PIN attempts on the pad beneath it): a biometric success
      // counts for nothing until the lockout expires.
      final still = await widget.capture.pinLockoutSecondsRemaining();
      if (!mounted) return;
      if (still <= 0) widget.onUnlocked();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _refreshLockout() async {
    final left = await widget.capture.pinLockoutSecondsRemaining();
    if (!mounted) return;
    _setLockout(left);
  }

  void _setLockout(int seconds) {
    _ticker?.cancel();
    setState(() => _lockoutLeft = seconds);
    if (seconds > 0) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _lockoutLeft = _lockoutLeft > 0 ? _lockoutLeft - 1 : 0);
        if (_lockoutLeft <= 0) t.cancel();
      });
    }
  }

  Future<void> _tryUnlock() async {
    if (_lockoutLeft > 0) return;
    final pin = _pin.text.trim();
    if (!isValidPinFormat(pin)) {
      setState(() => _error = 'Enter your 4–6 digit PIN');
      return;
    }
    setState(() => _busy = true);
    final res = await widget.capture.pinVerify(pin);
    if (!mounted) return;
    if (res.ok) {
      widget.onUnlocked();
      return;
    }
    setState(() {
      _busy = false;
      _pin.clear();
      if (res.lockoutSeconds > 0) {
        _error = 'Too many wrong PINs.';
        _setLockout(res.lockoutSeconds);
      } else {
        _error = 'Wrong PIN';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final lockedOut = _lockoutLeft > 0;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.lock_outline,
                size: 44,
                color: KanakkuTheme.orange,
              ),
              const SizedBox(height: 12),
              Text('Kanakku is locked', style: KanakkuTheme.serif(size: 22)),
              const SizedBox(height: 4),
              Text(
                'Enter your PIN to see your money data.',
                style: TextStyle(color: KanakkuTheme.inkSoft),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _pin,
                keyboardType: TextInputType.number,
                obscureText: true,
                autofocus: true,
                enabled: !lockedOut,
                textAlign: TextAlign.center,
                maxLength: 6,
                style: const TextStyle(fontSize: 24, letterSpacing: 8),
                decoration: InputDecoration(
                  errorText: _error,
                  counterText: '',
                  hintText: '••••',
                ),
                onSubmitted: (_) => _tryUnlock(),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: KanakkuTheme.orange,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _busy || lockedOut ? null : _tryUnlock,
                  child: Text(
                    lockedOut
                        ? 'Try again in $_lockoutLeft s'
                        : 'Unlock',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (lockedOut) ...[
                const SizedBox(height: 8),
                Text(
                  'PIN entry is paused after too many wrong attempts. '
                  'The wait doubles with each lockout.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: KanakkuTheme.inkSoft),
                ),
              ],
              // v1.1 (spec §5.4): biometrics are offered exactly
              // when the PIN pad is — and never during a lockout,
              // when this button disappears entirely (decision #4).
              if (!lockedOut &&
                  widget.biometricUnlock &&
                  _bioStatus == 'available') ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _promptBiometric,
                  icon: const Icon(Icons.fingerprint, size: 20),
                  label: const Text('Use fingerprint / face'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared PIN prompt (v1.0): used by the balance-privacy reveal in
/// the Shell and by the Settings PIN flows. Returns the entered PIN
/// or null when cancelled.
Future<String?> _askPinDialog(BuildContext context, String title) async {
  final ctl = TextEditingController();
  final pin = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        keyboardType: TextInputType.number,
        obscureText: true,
        autofocus: true,
        maxLength: 6,
        decoration: const InputDecoration(hintText: '4–6 digit PIN'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  ctl.dispose();
  return (pin == null || pin.isEmpty) ? null : pin;
}

/// Demo inbox: in production these arrive from the SMS receiver,
/// the notification listener and the Gmail sync — same parser.
const _demoSms = <(String, String)>[
  (
    'VM-YESBNK',
    'Rs.250.00 has been debited from your A/c XX1234 on 12-10-2026. Avl Bal: Rs.5,432.10.',
  ),
  (
    'AD-SBIBNK',
    'Dear UPI user, A/c X5678 debited by Rs 499.00 on 12Oct26. Trf to VPA swiggy@okhdfc (SWIGGY). Ref No 512345678901.',
  ),
  (
    'VM-HDFCBK',
    'Rs.1,200.00 debited from A/c **4321 on 12-10-26 at AMAZON INDIA. Avl bal Rs.23,450.00.',
  ),
  (
    'VM-ICICIB',
    'Dear Customer, your A/c XX9012 has been debited with INR 350.00 on 12-Oct-26. Info: UPI/UBER INDIA/123456. Avl Bal: INR 8,210.55.',
  ),
  (
    'VM-YESBNK',
    'Rs.45,000.00 credited to your A/c XX1234 on 01-10-2026 by NEFT SALARY OCT. Avl Bal: Rs.52,300.00.',
  ),
  (
    'VM-KOTAKB',
    'INR 2,499.00 spent on your Kotak Card 9876 at FLIPKART on 11-10-2026.',
  ),
  (
    'VM-YESBNK',
    'Your OTP is 483920 for a transaction of Rs.1,000.00. Do not share it.',
  ),
  // Card statement: not a transaction (no debit/credit verb) — feeds the
  // Bills section via CardBillParser instead.
  (
    'VM-HDFCBK',
    'Your HDFC Bank Credit Card XX4321 statement is ready. Total Amt Due: Rs.12,450.00, Min Amt Due: Rs.650.00. Payment due date: 05-Nov-2026. Ignore if paid.',
  ),
];

/// Demo bills, parsed from [_demoSms] with the same parser the real
/// capture path uses.
List<CardBill> _demoBills() {
  final out = <CardBill>[];
  for (final s in _demoSms) {
    final b = CardBillParser.parse(
      s.$2,
      sender: s.$1,
      receivedAt: DateTime(2026, 10, 25),
    );
    if (b != null) out.add(b);
  }
  return out;
}

const _monthAbbr = [
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

String _fmtDay(DateTime d) => '${d.day} ${_monthAbbr[d.month - 1]} ${d.year}';

/// Stable per-transaction identity (FNV-1a over the raw message + the
/// parser dedupe key + timestamp) lives in manual.dart since v1.1
/// (entryId / fnv1a) — the recurring engine must compute the very
/// same ids, so there is exactly one implementation.

class _Entry {
  final ParsedTransaction txn;
  final CategoryHit? hit;

  /// Free-text note kept alongside a manual entry; shown as the
  /// row subtitle when present.
  final String? note;

  /// Payment mode chosen for a manual entry (v1.0); null for
  /// captured/statement entries and older manual data.
  final String? mode;

  /// Single free-text tag on a manual entry (v1.0); drives the
  /// Transactions filter row.
  final String? tag;

  /// Manual categories/buckets are explicit user choices, not
  /// parser guesses (v1.0.1, ported from the v0.9.1 fix): when set
  /// they win over the merchant-table hit everywhere the entry's
  /// category or bucket is read.
  final String? manualCategory;
  final Bucket? manualBucket;

  /// v1.1 recurring provenance (spec §2.2): 'recurring' + the rule
  /// id for engine-generated entries; null for everything else.
  /// Drives the "↻ Recurring" tag in transaction lists.
  final String? origin;
  final String? recurringId;

  /// [hitOverride] lets the Shell's personal-rules wrapper decide
  /// the category (v1.0 Categories); without it the built-in
  /// merchant table runs, as before.
  _Entry(
    this.txn, {
    this.note,
    this.mode,
    this.tag,
    this.manualCategory,
    this.manualBucket,
    this.origin,
    this.recurringId,
    CategoryHit? hitOverride,
  }) : hit = hitOverride ?? categorize(txn.counterparty);
  String get id => entryId(txn);
  String get label {
    // Manual rows are named by the category the user picked.
    if (txn.source == TxnSource.manual && manualCategory != null) {
      return manualCategory!;
    }
    // Statement rows are named by their narration (the merchant /
    // description), not by the category the narration maps to.
    final party = txn.counterparty;
    if (txn.source == TxnSource.statement &&
        party != null &&
        party.isNotEmpty) {
      return party;
    }
    return hit?.category ??
        txn.counterparty ??
        (txn.direction == TxnDirection.credit ? 'Money in' : 'Expense');
  }

  String get category => manualCategory ?? hit?.category ?? 'Uncategorized';
  Bucket get bucket => manualBucket ?? hit?.bucket ?? Bucket.wants;
}

/// Period selector options (v0.7 reference design): every figure on
/// Home and Insights is computed for the selected period.
enum PeriodSel { thisMonth, lastMonth, allTime }

String periodLabel(PeriodSel p) => switch (p) {
  PeriodSel.thisMonth => 'This month',
  PeriodSel.lastMonth => 'Last month',
  PeriodSel.allTime => 'All time',
};

/// The "month" window containing [now] when months start on
/// [startDay] (v1.0 First Day of the Month, 1–28): with startDay 15,
/// October's window is Oct 15 → Nov 15. startDay 1 is the plain
/// calendar month — the pre-v1.0 behaviour.
(DateTime, DateTime) monthWindow(DateTime now, int startDay) {
  if (startDay <= 1) {
    return (DateTime(now.year, now.month), DateTime(now.year, now.month + 1));
  }
  var start = DateTime(now.year, now.month, startDay);
  if (now.day < startDay) {
    start = DateTime(now.year, now.month - 1, startDay);
  }
  return (start, DateTime(start.year, start.month + 1, startDay));
}

/// [start, end) bounds for a period selection. [startDay] is the
/// First-Day-of-the-Month setting; the default 1 keeps the
/// calendar-month behaviour every earlier version shipped.
(DateTime, DateTime) periodRange(
  PeriodSel p,
  DateTime now, [
  int startDay = 1,
]) => switch (p) {
  PeriodSel.thisMonth => monthWindow(now, startDay),
  PeriodSel.lastMonth => () {
    final (s, _) = monthWindow(now, startDay);
    return (DateTime(s.year, s.month - 1, startDay <= 1 ? 1 : startDay), s);
  }(),
  PeriodSel.allTime => (DateTime(2000), DateTime(2100)),
};

/// Page scroll padding for the five shell tabs. v1.0.1: the
/// bottom inset clears the floating glass footer so the last
/// rows can scroll fully into view while still sliding behind
/// the blur. v1.0.3: measured against the real footer footprint
/// (78 bar + 14 bottom margin + ~24 gesture-inset allowance =
/// 116), the old 120 left only ~4px of slack; 132 restores
/// ~16px of breathing room above the pill at end-of-scroll.
const _pagePadding = EdgeInsets.fromLTRB(20, 8, 20, 132);

class Shell extends StatefulWidget {
  final void Function(String) onThemePref;
  const Shell({super.key, required this.onThemePref});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _tab = 0;
  final _capture = CaptureService();

  /// v1.1: the raw manual-store maps — since the dual-amount rule
  /// (spec §1.1), the maps are the source of truth and [_manual]
  /// entries are rebuilt from them; persisting re-serialises the
  /// MAPS, never the entries, so additive keys (amountPaise,
  /// origin, recurringId, editedByUser) can never be dropped by a
  /// save.
  List<Map<String, dynamic>> _manualMaps = [];

  /// v1.1: recurring-rules document + budget-alert state, loaded on
  /// refresh, mutated by the engine pass / alert evaluation.
  Map<String, dynamic> _recurringDoc = emptyRecurringStore();
  Map<String, dynamic> _alertState = <String, dynamic>{};

  /// One-per-rule in-app notices from the latest engine pass
  /// (spec §3.3 step 0), shown on the Recurring screen.
  List<String> _recurringNotices = const [];

  /// True while a restore writes stores (spec §6.2): the engine
  /// pass and alert evaluation skip entirely.
  bool _restoreInProgress = false;

  /// App settings (v1.0): loaded from the native settings_store on
  /// refresh, pushed back on every change. Defaults = old behaviour.
  KanakkuSettings _settings = const KanakkuSettings();

  /// Personal categories + merchant rules (v1.0 Categories page).
  PersonalCategories _personal = const PersonalCategories();

  /// Balance privacy (v1.0): once the user reveals balances (with
  /// PIN verification when a PIN is set) they stay visible for the
  /// session.
  bool _balancesRevealed = false;

  /// Builds an entry whose category comes from the personal-rules
  /// wrapper (Categories page) rather than the built-in table alone.
  _Entry _mkEntry(
    ParsedTransaction t, {
    String? note,
    String? mode,
    String? tag,
    String? manualCategory,
    Bucket? manualBucket,
    String? origin,
    String? recurringId,
  }) => _Entry(
    t,
    note: note,
    mode: mode,
    tag: tag,
    manualCategory: manualCategory,
    manualBucket: manualBucket,
    origin: origin,
    recurringId: recurringId,
    hitOverride: categorizePersonal(t.counterparty, _personal),
  );

  /// Builds one Shell entry from a stored manual map.
  _Entry _entryFromManualMap(Map<String, dynamic> map) => _mkEntry(
    manualTxnFromJson(map),
    note: manualNoteFromJson(map),
    mode: manualModeFromJson(map),
    tag: manualTagFromJson(map),
    manualCategory: map['category']?.toString(),
    manualBucket: manualBucketFromJson(map),
    origin: map['origin']?.toString(),
    recurringId: map['recurringId']?.toString(),
  );

  /// Rebuilds [_manual] from [_manualMaps] after the maps changed
  /// underneath the entries (engine pass, entry edit, resolution).
  void _reloadManualEntries() {
    _manual
      ..clear()
      ..addAll([for (final m in _manualMaps) _entryFromManualMap(m)]);
  }

  /// Applies a settings change everywhere it matters: local state,
  /// native persistence, theme/format statics, and the reminder.
  Future<void> _applySettings(KanakkuSettings next) async {
    setState(() => _settings = next);
    KanakkuTheme.noDecimals = next.decimalFormat == 'none';
    KanakkuTheme.hour24 = next.timeFormat == '24h';
    widget.onThemePref(next.themeMode);
    await _capture.saveSettingsJson(encodeSettings(next));
    _pushDailySummary();
    // v1.1 (spec §4.1): a settings change can move the overall cap
    // or the alerts toggle — re-evaluate.
    await _evaluateBudgetAlerts();
  }

  bool _smsOn = false;
  bool _notifOn = false;
  bool _usingReal = false;
  final List<_Entry> _manual = [];
  final List<_Entry> _statement = [];
  final List<ParsedTransaction> _realCache = [];
  final List<CardBill> _billsCache = [];
  List<CardBill> _bills = const [];

  /// Selected period for Home/Insights figures (v0.7).
  PeriodSel _period = PeriodSel.thisMonth;

  /// Monthly category budgets (v0.7): defaults merged with the
  /// user's persisted edits.
  Map<String, double> _caps = Map.of(defaultBudgetCaps);

  /// User-removed transactions (spam/fakes). Persisted natively; parsed
  /// entries with a matching id are filtered out on every load, and any
  /// removed item can be restored from the Removed list.
  final List<Map<String, dynamic>> _removed = [];
  Set<String> get _removedIds => _removed.map((r) => r['id'] as String).toSet();

  /// Split bills (v0.5), persisted natively via the capture channel.
  final List<SplitRecord> _splits = [];

  late List<_Entry> _entries = _demoEntries();

  List<_Entry> _demoEntries() {
    final out = <_Entry>[];
    for (var i = 0; i < _demoSms.length; i++) {
      final p = KanakkuParser.parse(
        _demoSms[i].$2,
        sender: _demoSms[i].$1,
        receivedAt: DateTime(2026, 10, 25, 12, i),
      );
      if (p != null) out.add(_mkEntry(p));
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshCapture();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// v1.1 (spec §3.3/§4.1): the recurring pass and budget-alert
  /// evaluation re-run when the app comes back to the foreground —
  /// "on resume" is one of their three triggers.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshCapture();
  }

  void _rebuild() {
    final gone = _removedIds;
    List<_Entry> keep(List<_Entry> src) =>
        src.where((e) => !gone.contains(e.id)).toList();
    _usingReal =
        _realCache.isNotEmpty ||
        _smsOn ||
        _manual.isNotEmpty ||
        _statement.isNotEmpty;
    if (_usingReal) {
      _entries = [
        ...keep(_manual),
        ...keep(_statement),
        ...keep(_realCache.map((t) => _mkEntry(t)).toList()),
      ]..sort((a, b) => b.txn.receivedAt.compareTo(a.txn.receivedAt));
    } else {
      _entries = keep(_demoEntries());
    }
    _bills = _usingReal ? _billsCache : _demoBills();
  }

  Future<void> _refreshCapture() async {
    // v1.0: settings + personal categories first — entry building
    // and every figure below depend on them.
    _settings = decodeSettings(await _capture.loadSettingsJson());
    _personal = decodeCategories(await _capture.loadCategoriesJson());
    KanakkuTheme.noDecimals = _settings.decimalFormat == 'none';
    KanakkuTheme.hour24 = _settings.timeFormat == '24h';
    widget.onThemePref(_settings.themeMode);
    final sms = await _capture.hasSmsPermission();
    final notif = await _capture.isNotificationAccessEnabled();
    _removed.clear();
    try {
      final rj = jsonDecode(await _capture.loadRemovedJson()) as List<dynamic>;
      for (final r in rj) {
        _removed.add(Map<String, dynamic>.from(r as Map));
      }
    } catch (_) {}
    _splits.clear();
    _splits.addAll(decodeSplits(await _capture.loadSplitsJson()));
    _caps = decodeBudgets(await _capture.loadBudgetsJson());
    // v1.1: the manual maps are the source of truth (see
    // _manualMaps); entries are derived from them.
    _manualMaps = [];
    try {
      final mj = jsonDecode(await _capture.loadManualJson()) as List<dynamic>;
      for (final m in mj) {
        _manualMaps.add(Map<String, dynamic>.from(m as Map));
      }
    } catch (_) {}
    _reloadManualEntries();
    // v1.1: recurring document + alert state.
    _recurringDoc = decodeRecurringStore(await _capture.loadRecurringJson());
    _alertState = decodeAlertState(await _capture.loadAlertStateJson());
    // v1.1 (spec §6.2): a restore that crashed mid-write left the
    // restore_in_progress flag set — clear it and put the
    // recurring document, exactly as found, under the restore hold
    // before any engine pass runs.
    try {
      final rawSettings = jsonDecode(await _capture.loadSettingsJson());
      if (rawSettings is Map && rawSettings['restore_in_progress'] == true) {
        _recurringDoc = applyRestoreHold(
          _recurringDoc,
          dateStr(DateTime.now()),
        );
        await _capture.saveRecurringJson(encodeRecurringStore(_recurringDoc));
        final cleaned = Map<String, dynamic>.from(rawSettings)
          ..remove('restore_in_progress');
        await _capture.saveSettingsJson(jsonEncode(cleaned));
      }
    } catch (_) {}
    _statement.clear();
    try {
      final sj =
          jsonDecode(await _capture.loadStatementJson()) as List<dynamic>;
      for (final m in sj) {
        final map = m as Map<String, dynamic>;
        _statement.add(_statementEntryFromJson(map));
      }
    } catch (_) {}
    final real = await _capture.loadTransactions();
    final bills = await _capture.loadBills();
    if (!mounted) return;
    setState(() {
      _smsOn = sms;
      _notifOn = notif;
      _realCache
        ..clear()
        ..addAll(real);
      _billsCache
        ..clear()
        ..addAll(bills);
      _rebuild();
      _pushDailySummary();
    });
    // v1.1: with captures loaded (and the gate already passed —
    // the Shell only exists unlocked), run the recurring pass and
    // the budget-alert evaluation (spec §3.3/§4.1 triggers).
    await _runPostLoadPipeline();
  }

  /// v1.1: the budget-month key (spec §4.2): yyyy-mm of the budget
  /// window's start date, using the same monthWindow bucketing as
  /// every other "this month" figure.
  String _budgetMonthKey(DateTime now) {
    final (ws, _) = monthWindow(now, _settings.monthStartDay);
    return '${ws.year.toString().padLeft(4, '0')}-'
        '${ws.month.toString().padLeft(2, '0')}';
  }

  /// Occurrences waiting on a human decision (flagged) — the Home
  /// Recurring chip badge.
  int get _flaggedOccurrenceCount => rulesOf(_recurringDoc)
      .expand(occurrencesOf)
      .where((o) => o['state'] == 'flagged')
      .length;

  /// v1.1 post-load pipeline: recurring engine pass, then budget
  /// alert evaluation. Skipped entirely while a restore is in
  /// progress (spec §6.2, test T-R20).
  Future<void> _runPostLoadPipeline() async {
    if (_restoreInProgress) return;
    final res = runRecurringPass(
      store: _recurringDoc,
      manualMaps: _manualMaps,
      captures: _realCache,
      removedIds: _removedIds,
      now: DateTime.now(),
    );
    if (res.storeChanged) {
      _recurringDoc = res.store;
      await _capture.saveRecurringJson(encodeRecurringStore(res.store));
    }
    if (res.notices.isNotEmpty) _recurringNotices = res.notices;
    if (res.manualChanged) {
      _manualMaps = res.manualMaps;
      _reloadManualEntries();
      await _persistManual();
      if (mounted) setState(_rebuild);
    }
    await _evaluateBudgetAlerts();
  }

  /// v1.1 budget-alert evaluation (spec §4.1): runs after captures
  /// load, after the recurring pass, after manual add/edit/delete
  /// and after cap changes — app-open only (decision #5).
  Future<void> _evaluateBudgetAlerts() async {
    if (_restoreInProgress) return;
    final now = DateTime.now();
    final (ws, we) = monthWindow(now, _settings.monthStartDay);
    final alertTxns = [
      for (final e in _entries)
        AlertTxn(
          amountPaise: paiseFromRupees(e.txn.amount),
          isDebit: e.txn.direction == TxnDirection.debit,
          category: e.category,
          bucket: e.bucket,
          at: e.txn.receivedAt,
        ),
    ];
    final outcome = evaluateBudgetAlerts(
      state: _alertState,
      monthKey: _budgetMonthKey(now),
      capsPaise: {
        for (final e in _caps.entries) e.key: paiseFromRupees(e.value),
      },
      overallCapPaise: _settings.overallMonthlyCapPaise,
      spentByCategory: spentByCategoryPaise(alertTxns, ws, we),
      overallSpent: overallSpentPaise(alertTxns, ws, we),
      now: now,
      alertsOn: _settings.budgetAlertsOn,
      isForeground:
          WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed,
    );
    _alertState = outcome.state;
    if (outcome.stateChanged) {
      await _capture.saveAlertStateJson(encodeAlertState(_alertState));
    }
    if (outcome.wantsNotification) {
      final posted = await _capture.postBudgetAlert(
        outcome.notificationTitle!,
        outcome.notificationBody!,
      );
      if (posted) {
        // Only ACTUALLY posted notifications count toward the
        // 2/day cap (spec §4.3 rule 2).
        recordNotificationPosted(_alertState, now);
        await _capture.saveAlertStateJson(encodeAlertState(_alertState));
      }
    }
    if (mounted) setState(() {});
  }

  DailySummary get _summary {
    final now = DateTime.now();
    final (ws, we) = monthWindow(now, _settings.monthStartDay);
    return computeSummary(
      _entries
          .map(
            (e) => SummaryTxn(
              at: e.txn.receivedAt,
              amount: e.txn.amount,
              isDebit: e.txn.direction == TxnDirection.debit,
              category: e.category,
            ),
          )
          .toList(),
      now,
      monthStart: ws,
      monthEnd: we,
    );
  }

  /// Hands the fresh summary line to the native side so the daily
  /// reminder alarm posts up-to-date numbers at the user's chosen
  /// time (21:00 by default; OFF in Settings disarms it).
  void _pushDailySummary() {
    _capture.setDailySummary(
      _summary.line,
      _settings.dailyReminderOn,
      hour: _settings.dailyReminderHour,
      minute: _settings.dailyReminderMinute,
    );
  }

  Future<void> _sendTestSummary() async {
    await _capture.requestNotificationPermission();
    final line = _summary.line;
    final ok = await _capture.postSummaryNow(line);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Summary notification sent: $line' : 'Could not post the notification here — the 9 PM summary is still armed on your phone.',
        ),
      ),
    );
  }

  List<CsvTxnRow> _exportRows() => _entries
      .map(
        (e) => CsvTxnRow(
          date: e.txn.receivedAt,
          label: e.label,
          category: e.category,
          bucket: e.bucket.name,
          direction: e.txn.direction.name,
          amount: e.txn.amount,
          bank: e.txn.bankHint ?? '',
          accountLast4: e.txn.accountLast4 ?? '',
          source: e.txn.source.name,
        ),
      )
      .toList();

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Export chooser (Settings → Export Transactions): CSV or PDF.
  void _showExportChooser() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KanakkuTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.table_chart_outlined,
                color: KanakkuTheme.teal,
              ),
              title: const Text('Export as CSV'),
              onTap: () {
                Navigator.pop(ctx);
                _exportCsv();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.picture_as_pdf_outlined,
                color: KanakkuTheme.teal,
              ),
              title: const Text('Export as PDF'),
              onTap: () {
                Navigator.pop(ctx);
                _exportPdf();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// CSV export of everything currently listed (removed entries are
  /// already filtered out of [_entries]).
  Future<void> _exportCsv() async {
    final rows = _exportRows();
    final path = await _capture.shareCsv(
      'kanakku-transactions.csv',
      transactionsCsv(rows),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path.isEmpty
              ? 'Exported ${rows.length} transactions (share sheet unavailable here)'
              : 'Exported ${rows.length} transactions · saved to $path',
        ),
      ),
    );
  }

  /// PDF export (v0.5): hand-built PDF from the same rows, shared
  /// through the native FileProvider path.
  Future<void> _exportPdf() async {
    final rows = _exportRows();
    final bytes = buildTransactionsPdf(rows, generatedAt: DateTime.now());
    final path = await _capture.shareBytes(
      'kanakku-transactions.pdf',
      'application/pdf',
      bytes,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path.isEmpty
              ? 'PDF built for ${rows.length} transactions (share sheet unavailable here)'
              : 'PDF exported · ${rows.length} transactions · saved to $path',
        ),
      ),
    );
  }

  // ---- Split bills (v0.5) ------------------------------------------

  Future<void> _persistSplits() async {
    await _capture.saveSplitsJson(encodeSplits(_splits));
  }

  void _addSplit(SplitRecord split) {
    setState(() => _splits.insert(0, split));
    _persistSplits();
  }

  void _toggleShareSettled(String splitId, String name) {
    setState(() {
      final i = _splits.indexWhere((s) => s.id == splitId);
      if (i < 0) return;
      final s = _splits[i];
      _splits[i] = s.copyWith(
        shares: [
          for (final sh in s.shares)
            sh.name == name ? sh.copyWith(settled: !sh.settled) : sh,
        ],
      );
    });
    _persistSplits();
  }

  void _deleteSplit(String splitId) {
    setState(() => _splits.removeWhere((s) => s.id == splitId));
    _persistSplits();
  }

  void _openSplitSheet(_Entry e) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KanakkuTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _SplitSheet(
        entry: e,
        onSave: (split) {
          _addSplit(split);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Split saved · ${split.shares.length} people · ${split.label}',
              ),
            ),
          );
        },
      ),
    );
  }

  // ---- v1.0: backup / restore / wipe / categories ----------------

  Future<Map<String, String>> _allStoresJson() async => {
    'manual': await _capture.loadManualJson(),
    'removed': await _capture.loadRemovedJson(),
    'splits': await _capture.loadSplitsJson(),
    'budgets': await _capture.loadBudgetsJson(),
    'statement': await _capture.loadStatementJson(),
    'categories': await _capture.loadCategoriesJson(),
    // v1.1 (spec §6.2): recurring rules ride inside the same
    // backup envelope; alert state is never backed up.
    'recurring': await _capture.loadRecurringJson(),
  };

  /// Offers plain vs passphrase-encrypted backup (v1.0.4, audit
  /// F5). Returns 'plain', 'encrypted', or null when cancelled.
  Future<String?> _askBackupKind() => showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Backup Data'),
      content: const Text(
        'Encrypted backup (recommended): the file is locked with a '
        'passphrase only you know — safe to keep in WhatsApp, Drive '
        'or email. You will need the same passphrase to restore.\n\n'
        'Plain backup: readable by ANYONE who gets the file — it '
        'contains your full transaction history.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'plain'),
          child: const Text('Plain'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'encrypted'),
          child: const Text('Encrypt'),
        ),
      ],
    ),
  );

  /// Passphrase prompt. When [confirm] is true (creating a backup)
  /// the passphrase must be typed twice. Returns null on cancel, on
  /// a too-short passphrase, or on mismatch (already toasted).
  Future<String?> _askPassphrase({
    required String title,
    required bool confirm,
  }) async {
    final first = TextEditingController();
    final second = TextEditingController();
    final pass = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: first,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Passphrase'),
            ),
            if (confirm)
              TextField(
                controller: second,
                obscureText: true,
                decoration: const InputDecoration(hintText: 'Repeat passphrase'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, first.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (pass == null) {
      first.dispose();
      second.dispose();
      return null;
    }
    final p = pass.trim();
    final repeat = second.text.trim();
    first.dispose();
    second.dispose();
    if (p.length < 6) {
      _toast('Use a passphrase of at least 6 characters.');
      return null;
    }
    if (confirm && repeat != p) {
      _toast('Passphrases do not match — nothing was backed up.');
      return null;
    }
    return p;
  }

  /// Backup Data: one JSON with every store + the settings document
  /// (PIN excluded — it never leaves its own native store), shared
  /// through the FileProvider sheet. Records lastBackupAt.
  /// v1.0.4: optionally passphrase-encrypted (audit F5).
  Future<void> _doBackup() async {
    final kind = await _askBackupKind();
    if (kind == null || !mounted) return;
    final backup = buildBackup(
      stores: await _allStoresJson(),
      settings: _settings.toJson(),
      createdAt: DateTime.now(),
    );
    String fileText = encodeBackup(backup);
    if (kind == 'encrypted') {
      final pass = await _askPassphrase(
        title: 'Set a backup passphrase',
        confirm: true,
      );
      if (pass == null || !mounted) return;
      final blob = await _capture.encryptBackup(pass, fileText);
      if (blob == null) {
        _toast('Encryption is not available on this build');
        return;
      }
      fileText = encodeBackup(
        buildEncryptedBackup(data: blob, createdAt: DateTime.now()),
      );
    }
    final now = DateTime.now();
    final name =
        'kanakku-backup-${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}.json';
    final path = await _capture.shareBytes(
      name,
      'application/json',
      utf8.encode(fileText),
    );
    if (!mounted) return;
    if (path.isNotEmpty) {
      await _applySettings(
        _settings.copyWith(lastBackupAt: now.millisecondsSinceEpoch),
      );
      _toast('Backup file ready to share');
    } else {
      _toast('Sharing is not available on this build');
    }
  }

  /// Restore Data: pick a backup JSON, validate it, confirm, write
  /// every store back and reload the whole app state. Encrypted
  /// backups (v1.0.4) ask for their passphrase first; a wrong one
  /// aborts before anything is written.
  Future<void> _doRestore() async {
    final picked = await _capture.pickStatementFile();
    if (!mounted) return;
    if (picked == null || picked.data == null) {
      if (picked?.error != null) _toast(picked!.error!);
      return;
    }
    var parsed = parseBackup(utf8.decode(picked.data!, allowMalformed: true));
    if (parsed == null) {
      _toast('That file is not a Kanakku backup');
      return;
    }
    if (parsed.encryptedBlob != null) {
      final pass = await _askPassphrase(
        title: 'Enter the backup passphrase',
        confirm: false,
      );
      if (pass == null || !mounted) return;
      final plain = await _capture.decryptBackup(pass, parsed.encryptedBlob!);
      if (!mounted) return;
      if (plain == null) {
        _toast('Wrong passphrase — nothing was restored.');
        return;
      }
      parsed = parseBackup(plain);
      if (parsed == null || parsed.encryptedBlob != null) {
        _toast('That backup could not be read — nothing was restored.');
        return;
      }
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore backup?'),
        content: const Text(
          'This replaces ALL current Kanakku data with the backup. '
          'Anything added since the backup will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final s = parsed.stores;
    // v1.1 (spec §6.2): the restore_in_progress flag brackets the
    // whole write phase — set before the first write, cleared
    // after the last. If the app dies in between, the next launch
    // finds the flag and applies the restore hold to whatever
    // recurring document it finds (see _refreshCapture).
    _restoreInProgress = true;
    try {
      final rawSettings = jsonDecode(await _capture.loadSettingsJson());
      final flagDoc = rawSettings is Map
          ? Map<String, dynamic>.from(rawSettings)
          : <String, dynamic>{};
      flagDoc['restore_in_progress'] = true;
      await _capture.saveSettingsJson(jsonEncode(flagDoc));
    } catch (_) {}
    if (s.containsKey('manual')) await _capture.saveManualJson(s['manual']!);
    if (s.containsKey('removed')) {
      await _capture.saveRemovedJson(s['removed']!);
    }
    if (s.containsKey('splits')) await _capture.saveSplitsJson(s['splits']!);
    if (s.containsKey('budgets')) {
      await _capture.saveBudgetsJson(s['budgets']!);
    }
    if (s.containsKey('statement')) {
      await _capture.saveStatementJson(s['statement']!);
    }
    if (s.containsKey('categories')) {
      await _capture.saveCategoriesJson(s['categories']!);
    }
    // v1.1 (spec §6.2): an ABSENT 'recurring' key (a v1.0.4
    // backup) leaves the current rules untouched. A present one is
    // imported under the restore hold: every rule held, every
    // occurrence due before today rewritten to skipped.
    if (s.containsKey('recurring')) {
      final held = applyRestoreHold(
        decodeRecurringStore(s['recurring']!),
        dateStr(DateTime.now()),
      );
      await _capture.saveRecurringJson(encodeRecurringStore(held));
    }
    if (parsed.settings != null) {
      await _capture.saveSettingsJson(
        encodeSettings(
          // v1.1 (spec §5.5): a restored biometricUnlock flag is
          // inert — the user re-enables it on this device through
          // the PIN-verified toggle.
          KanakkuSettings.fromJson(
            parsed.settings!,
          ).copyWith(biometricUnlock: false),
        ),
      );
    }
    try {
      final rawSettings = jsonDecode(await _capture.loadSettingsJson());
      if (rawSettings is Map) {
        final cleaned = Map<String, dynamic>.from(rawSettings)
          ..remove('restore_in_progress');
        await _capture.saveSettingsJson(jsonEncode(cleaned));
      }
    } catch (_) {}
    _restoreInProgress = false;
    setState(() {
      _manual.clear();
      _manualMaps = [];
      _statement.clear();
      _removed.clear();
      _splits.clear();
    });
    await _refreshCapture();
    if (!mounted) return;
    _toast('Backup restored');
  }

  /// Danger zone: wipe everything (stores + settings + PIN) and
  /// return to the first-run/demo state.
  Future<void> _wipeAll() async {
    final ok = await _capture.wipeAllData();
    if (!mounted) return;
    if (!ok) {
      _toast('Wipe is not available on this build');
      return;
    }
    setState(() {
      _settings = const KanakkuSettings();
      _personal = const PersonalCategories();
      _manual.clear();
      _manualMaps = [];
      _statement.clear();
      _removed.clear();
      _splits.clear();
      _recurringDoc = emptyRecurringStore();
      _alertState = <String, dynamic>{};
      _recurringNotices = const [];
      _realCache.clear();
      _billsCache.clear();
      _bills = _demoBills();
      _usingReal = false;
      _balancesRevealed = false;
      _entries = _demoEntries();
      _tab = 0;
    });
    KanakkuTheme.noDecimals = false;
    KanakkuTheme.hour24 = false;
    widget.onThemePref('device');
    if (!mounted) return;
    _toast('All Kanakku data deleted');
  }

  Future<void> _savePersonal(PersonalCategories next) async {
    setState(() => _personal = next);
    await _capture.saveCategoriesJson(encodeCategories(next));
    _rebuild(); // personal rules can re-categorise existing entries
  }

  /// v1.1 (spec §2.3): a category rename moves its budget cap AND
  /// its current-month alert state to the new name, in the same
  /// user action — the alert history follows the category.
  Future<void> _onCategoryRenamed(String oldName, String newName) async {
    if (_caps.containsKey(oldName)) {
      final v = _caps.remove(oldName)!;
      _caps[newName] = v;
      await _capture.saveBudgetsJson(encodeBudgets(_caps));
    }
    renameCategoryAlertKey(
      _alertState,
      _budgetMonthKey(DateTime.now()),
      oldName,
      newName,
    );
    await _capture.saveAlertStateJson(encodeAlertState(_alertState));
    if (mounted) setState(_rebuild);
  }

  /// v1.1 (spec §2.3): deleting a category also removes its cap
  /// and its current-month alert state — if the category is ever
  /// re-added it starts with clean alert state (test T-B11).
  Future<void> _onCategoryDeleted(String name) async {
    if (_caps.remove(name) != null) {
      await _capture.saveBudgetsJson(encodeBudgets(_caps));
    }
    deleteCategoryAlertKey(_alertState, _budgetMonthKey(DateTime.now()), name);
    await _capture.saveAlertStateJson(encodeAlertState(_alertState));
    if (mounted) setState(_rebuild);
  }

  void _openCategories() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _CategoriesPage(
          personal: _personal,
          onSave: (p) async {
            await _savePersonal(p);
          },
          onRenameCategory: _onCategoryRenamed,
          onDeleteCategory: _onCategoryDeleted,
        ),
      ),
    );
  }

  /// v1.1: the Recurring screen (spec §3.1). The page works on
  /// copies and hands back the full updated documents; the Shell
  /// persists them and re-runs the pipeline.
  void _openRecurring() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RecurringPage(
          doc: decodeRecurringStore(encodeRecurringStore(_recurringDoc)),
          manualMaps: [
            for (final m in _manualMaps) Map<String, dynamic>.from(m),
          ],
          captures: List.of(_realCache),
          categoryDefs: _personal.allDefs,
          notices: _recurringNotices,
          onApply: (doc, maps) async {
            _recurringDoc = doc;
            _manualMaps = maps;
            await _capture.saveRecurringJson(encodeRecurringStore(doc));
            _reloadManualEntries();
            await _persistManual();
            if (mounted) setState(_rebuild);
            await _runPostLoadPipeline();
          },
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SettingsPage(
          capture: _capture,
          settings: _settings,
          onSettingsChanged: _applySettings,
          summaryLine: _summary.line,
          onBackup: _doBackup,
          onRestore: _doRestore,
          onExport: _showExportChooser,
          onImportStatement: _uploadStatement,
          onOpenCategories: _openCategories,
          onWipeData: _wipeAll,
          onJumpTab: (i) {
            setState(() => _tab = i);
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  // ---- Budgets (v0.7) ----------------------------------------------

  Future<void> _editBudget(String category) async {
    final ctrl = TextEditingController(
      text: (_caps[category] ?? 0).toStringAsFixed(0),
    );
    final result = await showDialog<(String, double?)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Monthly budget — $category'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: const InputDecoration(
            prefixText: '₹ ',
            labelText: 'Budget per month',
          ),
        ),
        actions: [
          // v1.1 (spec §2.3): removing a cap also clears the
          // category's current-month alert state.
          if (_caps.containsKey(category))
            TextButton(
              onPressed: () => Navigator.pop(ctx, ('remove', null)),
              child: const Text('Remove budget'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              ('save', double.tryParse(ctrl.text.replaceAll(',', ''))),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null) return;
    if (result.$1 == 'remove') {
      setState(() => _caps = {..._caps}..remove(category));
      await _capture.saveBudgetsJson(encodeBudgets(_caps));
      deleteCategoryAlertKey(
        _alertState,
        _budgetMonthKey(DateTime.now()),
        category,
      );
      await _capture.saveAlertStateJson(encodeAlertState(_alertState));
      if (mounted) setState(() {});
      return;
    }
    final value = result.$2;
    if (value == null || value < 0) return;
    setState(() => _caps = {..._caps, category: value});
    await _capture.saveBudgetsJson(encodeBudgets(_caps));
    // v1.1 (spec §4.1): a cap edit re-runs alert evaluation.
    await _evaluateBudgetAlerts();
  }

  // ---- Bank statement import (v0.7) --------------------------------

  _Entry _statementEntryFromRow(StatementRow r) => _mkEntry(
    ParsedTransaction(
      amount: r.amount,
      direction: r.isDebit ? TxnDirection.debit : TxnDirection.credit,
      source: TxnSource.statement,
      receivedAt: DateTime(r.date.year, r.date.month, r.date.day, 12),
      rawBody: 'Statement import: ${r.description}',
      counterparty: r.description.isEmpty ? null : r.description,
      balanceAfter: r.balanceAfter,
      bankHint: 'Statement',
    ),
  );

  _Entry _statementEntryFromJson(Map<String, dynamic> map) => _mkEntry(
    ParsedTransaction(
      amount: (map['amount'] as num).toDouble(),
      direction: map['dir'] == 'credit'
          ? TxnDirection.credit
          : TxnDirection.debit,
      source: TxnSource.statement,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['ts'] as num).toInt(),
      ),
      rawBody: 'Statement import: ${map['desc'] ?? ''}',
      counterparty: map['desc']?.toString(),
      balanceAfter: (map['bal'] as num?)?.toDouble(),
      bankHint: 'Statement',
    ),
  );

  Future<void> _persistStatement() async {
    final json = jsonEncode(
      _statement
          .map(
            (e) => {
              'amount': e.txn.amount,
              'dir': e.txn.direction.name,
              'ts': e.txn.receivedAt.millisecondsSinceEpoch,
              'desc': e.txn.counterparty ?? '',
              'bal': e.txn.balanceAfter,
            },
          )
          .toList(),
    );
    await _capture.saveStatementJson(json);
  }

  void _importStatementRows(List<StatementRow> rows) {
    setState(() {
      for (final r in rows) {
        _statement.add(_statementEntryFromRow(r));
      }
      _rebuild();
    });
    _persistStatement();
  }

  /// Upload flow: native picker → PDF notice or CSV parse → import
  /// preview (duplicates excluded) → import → analysis.
  Future<void> _uploadStatement() async {
    final picked = await _capture.pickStatementFile();
    if (picked == null || !mounted) return; // cancelled
    if (picked.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            picked.error == 'too_large'
                ? 'That file is over 5 MB — try a shorter statement period.'
                : 'Could not read that file. Please try again.',
          ),
        ),
      );
      return;
    }
    final isPdf =
        picked.mime.contains('pdf') ||
        picked.name.toLowerCase().endsWith('.pdf');
    if (isPdf) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const _PdfNoticePage()));
      return;
    }
    final data = picked.data;
    if (data == null) return;
    final result = parseStatementCsv(utf8.decode(data, allowMalformed: true));
    if (!mounted) return;
    if (result.rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No transactions found in that file. Make sure it is the CSV statement from your bank app.',
          ),
        ),
      );
      return;
    }
    final existingKeys = [
      for (final e in _entries)
        statementDedupeKey(
          e.txn.receivedAt,
          e.txn.amount,
          e.txn.direction == TxnDirection.debit,
          e.txn.counterparty ?? e.label,
        ),
    ];
    final imported = await Navigator.of(context).push<int>(
      MaterialPageRoute<int>(
        builder: (_) => _ImportPreviewPage(
          rows: result.rows,
          existingKeys: existingKeys,
          onImport: _importStatementRows,
        ),
      ),
    );
    if (imported != null && imported > 0 && mounted) {
      _openAnalysis();
    }
  }

  List<AnalysisTxn> get _statementAnalysisTxns => [
    for (final e in _statement)
      AnalysisTxn(
        at: e.txn.receivedAt,
        description: e.txn.counterparty ?? e.label,
        amount: e.txn.amount,
        isDebit: e.txn.direction == TxnDirection.debit,
        category: e.category,
      ),
  ];

  void _openAnalysis() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _StatementAnalysisPage(
          analysis: analyzeTransactions(_statementAnalysisTxns),
        ),
      ),
    );
  }

  // ---- Removed / manual (unchanged behaviour) -----------------------

  Future<void> _persistRemoved() async {
    await _capture.saveRemovedJson(jsonEncode(_removed));
  }

  void _removeEntry(_Entry e, BuildContext context) {
    final rec = <String, dynamic>{
      'id': e.id,
      'amount': e.txn.amount,
      'label': e.label,
      'ts': e.txn.receivedAt.millisecondsSinceEpoch,
      'direction': e.txn.direction.name,
      'source': e.txn.source.name,
    };
    setState(() {
      _removed.add(rec);
      _rebuild();
    });
    _persistRemoved();
    // v1.1: totals changed — re-run pass + alert evaluation.
    _runPostLoadPipeline();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed ${e.label} · ${KanakkuTheme.inr(e.txn.amount)}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _restoreRecord(rec),
        ),
      ),
    );
  }

  void _restoreRecord(Map<String, dynamic> rec) {
    setState(() {
      _removed.removeWhere((r) => r['id'] == rec['id']);
      _rebuild();
    });
    _persistRemoved();
    _runPostLoadPipeline();
  }

  void _showRemovedSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KanakkuTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Removed transactions',
                  style: KanakkuTheme.serif(size: 17),
                ),
                const SizedBox(height: 4),
                Text(
                  'Spam and fake entries you filtered out. They stay out of your totals until restored.',
                  style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
                ),
                const SizedBox(height: 12),
                if (_removed.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Nothing removed yet.',
                      style: TextStyle(color: KanakkuTheme.inkSoft),
                    ),
                  )
                else
                  ..._removed.map(
                    (r) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        r['label']?.toString() ?? 'Expense',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        DateTime.fromMillisecondsSinceEpoch(
                          (r['ts'] as num).toInt(),
                        ).toString().substring(0, 10),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${r['direction'] == 'credit' ? '+' : '-'}${KanakkuTheme.inr((r['amount'] as num).toDouble())}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              _restoreRecord(r);
                              setSheet(() {});
                            },
                            child: const Text('Restore'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// v1.1: persists [_manualMaps] verbatim. (Pre-v1.1 this rebuilt
  /// each map from its _Entry via manualToJson — which would have
  /// silently dropped the additive v1.1 keys on every save.)
  Future<void> _persistManual() async {
    final saved = await _capture.saveManualJson(jsonEncode(_manualMaps));
    if (!saved) {
      throw StateError(
        'Kanakku could not save this transaction to device storage.',
      );
    }
  }

  /// Manual EXPENSE. v1.0.1 (v0.9.1 fix ported): the note is its
  /// own field — it no longer replaces the picked subcategory —
  /// and the picked category + bucket are stored on the entry and
  /// persisted. The save is awaited; when the native write reports
  /// failure the entry is rolled back out of the in-memory list
  /// and the error rethrown so the Add sheet can tell the user.
  Future<void> _addManual(
    double amount,
    Bucket bucket,
    String category,
    String note,
    DateTime date,
    String mode,
    String tag,
  ) async {
    // v0.9 date option: picked calendar date + current time-of-day.
    final stamp = manualStamp(date, DateTime.now());
    // v1.1: build the store map first (dual amount written
    // atomically by manualToJson), then derive the entry from it.
    final map = manualToJson(
      amount: amount,
      label: category,
      at: stamp,
      direction: TxnDirection.debit,
      note: note.isEmpty ? null : note,
      bucket: bucket,
      mode: mode,
      tag: tag.isEmpty ? null : tag,
    );
    final entry = _entryFromManualMap(map);
    setState(() {
      _manualMaps.insert(0, map);
      _manual.insert(0, entry);
      _rebuild();
    });
    try {
      await _persistManual();
    } catch (_) {
      if (mounted) {
        setState(() {
          _manualMaps.remove(map);
          _manual.removeWhere((e) => e.id == entry.id);
          _rebuild();
        });
      }
      rethrow;
    }
    // v1.1 (spec §3.3/§4.1): manual changes re-run the pass +
    // alert evaluation.
    await _runPostLoadPipeline();
  }

  /// Manual INCOME (v0.8): a credit entry whose label is the chosen
  /// income type (Salary, Bonus, … or the custom "Other" name). The
  /// label is stored as the counterparty verbatim, so categorize()
  /// can never rename what the user picked; the optional note rides
  /// along and shows as the row subtitle. v1.0.1: same awaited,
  /// rollback-on-failure save as [_addManual].
  Future<void> _addIncome(
    double amount,
    String label,
    String note,
    DateTime date,
    String mode,
    String tag,
  ) async {
    // v0.9 date option: picked calendar date + current time-of-day.
    final stamp = manualStamp(date, DateTime.now());
    // v1.1: map first, entry derived (see _addManual).
    final map = manualToJson(
      amount: amount,
      label: label,
      at: stamp,
      direction: TxnDirection.credit,
      note: note.isEmpty ? null : note,
      mode: mode,
      tag: tag.isEmpty ? null : tag,
    );
    final entry = _entryFromManualMap(map);
    setState(() {
      _manualMaps.insert(0, map);
      _manual.insert(0, entry);
      _rebuild();
    });
    try {
      await _persistManual();
    } catch (_) {
      if (mounted) {
        setState(() {
          _manualMaps.remove(map);
          _manual.removeWhere((e) => e.id == entry.id);
          _rebuild();
        });
      }
      rethrow;
    }
    await _runPostLoadPipeline();
  }

  /// v1.1: edit a manual entry (amount + note). The spec's
  /// dual-amount rule (§1.1, test T-M4) and the sweep's
  /// edited-entry protection (§3.3 step 4) both hang off this
  /// path: applyManualEdit recomputes amountPaise in the same
  /// write and stamps editedByUser on recurring-generated entries.
  /// (v1.0.4 had no entry-edit UI at all; this is the minimal one
  /// the spec's rules require.)
  Future<void> _editManualEntry(_Entry e) async {
    final idx = _manualMaps.indexWhere(
      (m) => entryId(manualTxnFromJson(m)) == e.id,
    );
    if (idx < 0) return;
    final map = _manualMaps[idx];
    final amountCtl = TextEditingController(
      text: (map['amount'] as num).toStringAsFixed(2),
    );
    final noteCtl = TextEditingController(text: map['note']?.toString() ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit — ${map['label']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autofocus: true,
              decoration: const InputDecoration(
                prefixText: '₹ ',
                labelText: 'Amount',
              ),
            ),
            TextField(
              controller: noteCtl,
              decoration: const InputDecoration(labelText: 'Note'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final newAmount = double.tryParse(amountCtl.text.replaceAll(',', ''));
    final newNote = noteCtl.text.trim();
    amountCtl.dispose();
    noteCtl.dispose();
    if (saved != true || newAmount == null || newAmount <= 0) return;
    applyManualEdit(map, amount: newAmount, note: newNote);
    try {
      await _persistManual();
    } catch (_) {
      _toast('Could not save the edit — storage write failed.');
      return;
    }
    _reloadManualEntries();
    if (mounted) setState(_rebuild);
    await _runPostLoadPipeline();
  }

  /// v1.1 "Repeat this" (spec §3.1): long-press any transaction to
  /// create a recurring rule pre-filled from it. The first due
  /// date is the entry's day-of-month, today or next month.
  Future<void> _startRepeat(_Entry e) async {
    final now = DateTime.now();
    var first = DateTime(now.year, now.month, e.txn.receivedAt.day);
    if (first.isBefore(DateTime(now.year, now.month, now.day))) {
      first = DateTime(now.year, now.month + 1, e.txn.receivedAt.day);
    }
    final draft = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => _RuleFormPage(
          categoryDefs: _personal.allDefs,
          initial: {
            'label': e.label,
            'matchText': e.label,
            'amountPaise': paiseFromRupees(e.txn.amount),
            'dir': e.txn.direction.name,
            'category': e.category,
            'bucket': e.bucket.name,
            'mode': e.mode ?? _settings.defaultPaymentMode,
            'interval': {
              'type': 'monthly',
              'every': 1,
              'dayOfMonth': e.txn.receivedAt.day,
            },
            'startDate': dateStr(first),
            'capturePolicy':
                (e.mode ?? _settings.defaultPaymentMode) == 'Cash'
                ? 'auto'
                : 'matchOrPost',
          },
        ),
      ),
    );
    if (draft == null || !mounted) return;
    final doc = decodeRecurringStore(encodeRecurringStore(_recurringDoc));
    draft['id'] = newRuleId(doc, DateTime.now().millisecondsSinceEpoch);
    rulesOf(doc).add(normalizeRule(draft));
    _recurringDoc = doc;
    await _capture.saveRecurringJson(encodeRecurringStore(doc));
    _toast('Recurring rule created');
    await _runPostLoadPipeline();
  }

  List<_Entry> get _periodEntries {
    final (start, end) = periodRange(
      _period,
      DateTime.now(),
      _settings.monthStartDay,
    );
    return _entries
        .where(
          (e) =>
              !e.txn.receivedAt.isBefore(start) &&
              e.txn.receivedAt.isBefore(end),
        )
        .toList();
  }

  /// The current custom-month window (First Day of the Month) —
  /// Budgets and the Home check-in measure "this month" inside it.
  (DateTime, DateTime) get _monthWin =>
      monthWindow(DateTime.now(), _settings.monthStartDay);

  @override
  Widget build(BuildContext context) {
    final pages = [
      _Home(
        entries: _entries,
        periodEntries: _periodEntries,
        period: _period,
        onPeriodChanged: (p) => setState(() => _period = p),
        accounts: latestBalances(_entries.map((e) => e.txn).toList()),
        bills: _bills,
        summary: _summary,
        caps: _caps,
        smsOn: _smsOn,
        notifOn: _notifOn,
        usingReal: _usingReal,
        hasStatement: _statement.isNotEmpty,
        balanceView: _settings.homeBalanceView,
        balancesHidden: _settings.balancePrivacy && !_balancesRevealed,
        onRevealBalances: _revealBalances,
        windowStart: _monthWin.$1,
        windowEnd: _monthWin.$2,
        onEnableSms: () async {
          if (await _capture.requestSmsPermission()) _refreshCapture();
        },
        onEnableNotif: () async {
          await _capture.openNotificationSettings();
        },
        onRefresh: _refreshCapture,
        onRemove: (e) => _removeEntry(e, context),
        onSplit: _openSplitSheet,
        onTestSummary: _sendTestSummary,
        onExportCsv: _exportCsv,
        onExportPdf: _exportPdf,
        onViewAll: () => setState(() => _tab = 1),
        onAdd: () => _openAdd(context),
        onEditBudget: _editBudget,
        onManageBudgets: () => setState(() => _tab = 2),
        onUploadStatement: _uploadStatement,
        onOpenAnalysis: _openAnalysis,
        // v1.1: budget-alert banner + Recurring entry point.
        bannerLines: bannerLines(
          _alertState,
          _budgetMonthKey(DateTime.now()),
          DateTime.now(),
        ),
        onDismissBanner: () async {
          dismissBanner(_alertState, DateTime.now());
          await _capture.saveAlertStateJson(encodeAlertState(_alertState));
          if (mounted) setState(() {});
        },
        onOpenRecurring: _openRecurring,
        recurringFlagged: _flaggedOccurrenceCount,
        onRepeat: _startRepeat,
        onEditEntry: _editManualEntry,
      ),
      _Transactions(
        entries: _entries,
        onRemove: (e) => _removeEntry(e, context),
        onSplit: _openSplitSheet,
        removedCount: _removed.length,
        onOpenRemoved: () => _showRemovedSheet(context),
        onAdd: () => _openAdd(context),
        onUploadStatement: _uploadStatement,
        onRepeat: _startRepeat,
        onEditEntry: _editManualEntry,
      ),
      _Budgets(
        entries: _entries,
        caps: _caps,
        onEditBudget: _editBudget,
        windowStart: _monthWin.$1,
        windowEnd: _monthWin.$2,
        firedByCategory: {
          for (final c in _caps.keys)
            c: firedThresholds(
              _alertState,
              _budgetMonthKey(DateTime.now()),
              categoryAlertKey(c),
            ),
        },
      ),
      _Insights(
        entries: _entries,
        period: _period,
        onPeriodChanged: (p) => setState(() => _period = p),
        onExportCsv: _exportCsv,
        onExportPdf: _exportPdf,
        hasStatement: _statement.isNotEmpty,
        onOpenAnalysis: _openAnalysis,
        monthStartDay: _settings.monthStartDay,
      ),
      _SplitsPage(
        splits: _splits,
        onToggleShare: _toggleShareSettled,
        onDelete: _deleteSplit,
      ),
    ];
    return Scaffold(
      // v1.0.1: the glass footer floats — page content scrolls
      // behind its blur (each page carries extra bottom padding
      // so its last rows can still scroll clear of the pill).
      extendBody: true,
      body: Column(
        children: [
          _BrandBar(onSettings: _openSettings),
          Expanded(child: pages[_tab]),
        ],
      ),
      bottomNavigationBar: _GlassBottomNav(
        selected: _tab,
        onSelect: (i) {
          if (_settings.haptics) HapticFeedback.selectionClick();
          setState(() => _tab = i);
        },
        onAdd: () {
          if (_settings.haptics) HapticFeedback.selectionClick();
          _openAdd(context);
        },
      ),
    );
  }

  /// Balance privacy (v1.0): tap on a masked balance — verify the
  /// PIN when one is set, otherwise just reveal for the session.
  Future<void> _revealBalances() async {
    if (await _capture.pinIsSet()) {
      if (!mounted) return;
      final pin = await _askPinDialog(context, 'Enter PIN to show balances');
      if (pin == null) return;
      // Counted verify (v1.0.4): this prompt shares the lock
      // screen's failure counter and lockout.
      final res = await _capture.pinVerify(pin);
      if (!res.ok) {
        _toast(
          res.lockoutSeconds > 0
              ? 'Too many wrong PINs — try again in ${res.lockoutSeconds}s'
              : 'Wrong PIN',
        );
        return;
      }
    }
    if (!mounted) return;
    setState(() => _balancesRevealed = true);
  }

  void _openAdd(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KanakkuTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _AddSheet(
        onSave: _addManual,
        onSaveIncome: _addIncome,
        defaultMode: _settings.defaultPaymentMode,
        defaultExpenseCategory: _settings.defaultExpenseCategory,
        defaultIncomeCategory: _settings.defaultIncomeCategory,
      ),
    );
  }
}

/// Manual add sheet. Expense mode is the original 3-tap flow
/// (amount -> bucket -> subcategory -> save). Income mode (v0.8,
/// Guna's request) swaps the bucket/subcategory pickers for income
/// type chips (Salary, Bonus, …) with a custom name for "Other".
/// Both modes share the v0.9 date row: the entry can be backdated
/// (or future-dated) instead of always landing on today.
class _AddSheet extends StatefulWidget {
  final Future<void> Function(
    double,
    Bucket,
    String,
    String,
    DateTime,
    String,
    String,
  )
  onSave;
  final Future<void> Function(double, String, String, DateTime, String, String)
  onSaveIncome;

  /// v1.0 preference defaults (Settings → Preferences): the sheet
  /// opens with these pre-selected.
  final String defaultMode;
  final String defaultExpenseCategory;
  final String defaultIncomeCategory;
  const _AddSheet({
    required this.onSave,
    required this.onSaveIncome,
    this.defaultMode = 'Cash',
    this.defaultExpenseCategory = 'Groceries',
    this.defaultIncomeCategory = 'Salary',
  });
  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _customType = TextEditingController();
  final _tag = TextEditingController();
  bool _isIncome = false;
  Bucket _bucket = Bucket.needs;
  static const _subs = {
    Bucket.needs: ['Groceries', 'Rent', 'Utilities', 'Travel', 'Health'],
    Bucket.wants: [
      'Food Delivery',
      'Shopping',
      'Entertainment',
      'Subscriptions',
    ],
    Bucket.savings: ['Investments', 'Emergency Fund'],
  };
  String _sub = 'Groceries';
  String _incomeType = incomeTypes.first;

  /// v1.0: payment mode + defaults from Settings → Preferences.
  late String _mode = widget.defaultMode;

  @override
  void initState() {
    super.initState();
    if (incomeTypes.contains(widget.defaultIncomeCategory)) {
      _incomeType = widget.defaultIncomeCategory;
    }
    for (final b in Bucket.values) {
      if (_subs[b]!.contains(widget.defaultExpenseCategory)) {
        _bucket = b;
        _sub = widget.defaultExpenseCategory;
      }
    }
  }

  /// v0.9 date option: the calendar date stamped on the entry.
  /// Defaults to today; the picker allows 2020-01-01 through
  /// today + 366 days (future-dated salary/cheque entries).
  DateTime _date = DateTime.now();

  /// v1.0.1: true while the awaited native save is in flight —
  /// the Save button disables and spins instead of double-saving.
  bool _saving = false;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String get _dateLabel {
    final now = DateTime.now();
    final base = _fmtDay(_date);
    if (_sameDay(_date, now)) return 'Today · $base';
    if (_sameDay(_date, now.subtract(const Duration(days: 1)))) {
      return 'Yesterday · $base';
    }
    if (_sameDay(_date, now.add(const Duration(days: 1)))) {
      return 'Tomorrow · $base';
    }
    return base;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day + 366),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme
              .copyWith(primary: KanakkuTheme.teal),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    // Scrollable: with the v0.9 date row the sheet can exceed the
    // viewport on small screens / in income mode.
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isIncome ? 'Add income' : 'Log expense',
            style: KanakkuTheme.serif(size: 19),
          ),
          const SizedBox(height: 12),
          // Expense | Income toggle (v0.8), teal selected state.
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                value: false,
                icon: Icon(Icons.arrow_upward_rounded, size: 16),
                label: Text('Expense'),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: Icon(Icons.arrow_downward_rounded, size: 16),
                label: Text('Income'),
              ),
            ],
            selected: {_isIncome},
            onSelectionChanged: (s) => setState(() => _isIncome = s.first),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: KanakkuTheme.teal,
              selectedForegroundColor: Colors.white,
              foregroundColor: KanakkuTheme.teal,
              side: const BorderSide(color: KanakkuTheme.teal),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            decoration: const InputDecoration(
              prefixText: '₹ ',
              border: InputBorder.none,
              hintText: '0',
            ),
          ),
          const SizedBox(height: 8),
          // v0.9 date row (both modes): tap to open the calendar.
          InkWell(
            onTap: _pickDate,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: KanakkuTheme.tealSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.calendar_month_outlined,
                    size: 18,
                    color: KanakkuTheme.tealDark,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _dateLabel,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: KanakkuTheme.tealDark,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: KanakkuTheme.tealDark,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              ChoiceChip(
                label: const Text('Today'),
                selected: _sameDay(_date, DateTime.now()),
                selectedColor: KanakkuTheme.tealSoft,
                onSelected: (_) => setState(() => _date = DateTime.now()),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Yesterday'),
                selected: _sameDay(
                  _date,
                  DateTime.now().subtract(const Duration(days: 1)),
                ),
                selectedColor: KanakkuTheme.tealSoft,
                onSelected: (_) => setState(
                  () =>
                      _date = DateTime.now().subtract(const Duration(days: 1)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_isIncome) ...[
            Row(
              children: [
                for (final b in Bucket.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        b.name[0].toUpperCase() + b.name.substring(1),
                      ),
                      selected: _bucket == b,
                      onSelected: (_) => setState(() {
                        _bucket = b;
                        _sub = _subs[b]!.first;
                      }),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _sub,
              items: _subs[_bucket]!
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _sub = v!),
              decoration: const InputDecoration(labelText: 'Subcategory'),
            ),
          ] else ...[
            Text(
              'Income type',
              style: TextStyle(
                color: KanakkuTheme.inkSoft,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final t in incomeTypes)
                  ChoiceChip(
                    label: Text(t),
                    selected: _incomeType == t,
                    selectedColor: KanakkuTheme.tealSoft,
                    onSelected: (_) => setState(() => _incomeType = t),
                  ),
              ],
            ),
            if (_incomeType == 'Other')
              TextField(
                controller: _customType,
                decoration: const InputDecoration(
                  labelText: 'Income name',
                  hintText: 'e.g. Sold old phone',
                ),
              ),
          ],
          const SizedBox(height: 10),
          // v1.0: payment mode (defaults to the Preferences setting).
          Text(
            'Payment mode',
            style: TextStyle(
              color: KanakkuTheme.inkSoft,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final m in paymentModes)
                ChoiceChip(
                  label: Text(m),
                  selected: _mode == m,
                  selectedColor: KanakkuTheme.tealSoft,
                  onSelected: (_) => setState(() => _mode = m),
                ),
            ],
          ),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
          // v1.0: single optional tag (drives the Transactions filter).
          TextField(
            controller: _tag,
            decoration: const InputDecoration(
              labelText: 'Tag (optional)',
              hintText: 'e.g. Trip, Office, Family',
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: KanakkuTheme.orange,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _saving
                  ? null
                  : () async {
                      final v = double.tryParse(
                        _amount.text.replaceAll(',', ''),
                      );
                      if (v == null || v <= 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Enter an amount greater than zero.',
                            ),
                          ),
                        );
                        return;
                      }
                      // Captured before the await so neither is
                      // reached through a BuildContext across the
                      // async gap.
                      final navigator = Navigator.of(context);
                      final messenger = ScaffoldMessenger.of(context);
                      setState(() => _saving = true);
                      try {
                        if (_isIncome) {
                          final custom = _customType.text.trim();
                          final label = _incomeType == 'Other'
                              ? (custom.isEmpty ? 'Other' : custom)
                              : _incomeType;
                          await widget.onSaveIncome(
                            v,
                            label,
                            _note.text.trim(),
                            _date,
                            _mode,
                            _tag.text.trim(),
                          );
                        } else {
                          await widget.onSave(
                            v,
                            _bucket,
                            _sub,
                            _note.text.trim(),
                            _date,
                            _mode,
                            _tag.text.trim(),
                          );
                        }
                        if (mounted) navigator.pop();
                      } catch (_) {
                        if (mounted) {
                          setState(() => _saving = false);
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Could not save transaction. Please try again.',
                              ),
                            ),
                          );
                        }
                      }
                    },
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _isIncome ? 'Add income' : 'Save',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Home / Overview (v0.7, reference layout): greeting + serif
/// headline, period selector, teal TOTAL BALANCE hero, 2×2 stat
/// grid, then the kept features restyled as white cards — Today,
/// capture chips, Accounts, Card bills due, Budget check-in,
/// statement upload, Recent transactions.
class _Home extends StatelessWidget {
  final List<_Entry> entries;
  final List<_Entry> periodEntries;
  final PeriodSel period;
  final void Function(PeriodSel) onPeriodChanged;
  final List<AccountBalance> accounts;
  final List<CardBill> bills;
  final DailySummary summary;
  final Map<String, double> caps;
  final bool smsOn;
  final bool notifOn;
  final bool usingReal;
  final bool hasStatement;
  final VoidCallback onEnableSms;
  final VoidCallback onEnableNotif;
  final VoidCallback onRefresh;
  final void Function(_Entry) onRemove;
  final void Function(_Entry) onSplit;
  final VoidCallback onTestSummary;
  final VoidCallback onExportCsv;
  final VoidCallback onExportPdf;
  final VoidCallback onViewAll;
  final VoidCallback onAdd;
  final void Function(String) onEditBudget;
  final VoidCallback onManageBudgets;
  final VoidCallback onUploadStatement;
  final VoidCallback onOpenAnalysis;

  /// v1.1 budget-alert banner (spec §4.4): today's crossings +
  /// suppressed crossings, dismissible once per day.
  final List<String> bannerLines;
  final VoidCallback onDismissBanner;

  /// v1.1 Recurring: Home shortcut chip + flagged badge count.
  final VoidCallback onOpenRecurring;
  final int recurringFlagged;

  /// v1.1: long-press actions on transaction rows.
  final void Function(_Entry) onRepeat;
  final void Function(_Entry) onEditEntry;
  const _Home({
    required this.entries,
    required this.periodEntries,
    required this.period,
    required this.onPeriodChanged,
    required this.accounts,
    required this.bills,
    required this.summary,
    required this.caps,
    required this.smsOn,
    required this.notifOn,
    required this.usingReal,
    required this.hasStatement,
    required this.onEnableSms,
    required this.onEnableNotif,
    required this.onRefresh,
    required this.onRemove,
    required this.onSplit,
    required this.onTestSummary,
    required this.onExportCsv,
    required this.onExportPdf,
    required this.onViewAll,
    required this.onAdd,
    required this.onEditBudget,
    required this.onManageBudgets,
    required this.onUploadStatement,
    required this.onOpenAnalysis,
    required this.balanceView,
    required this.balancesHidden,
    required this.onRevealBalances,
    required this.windowStart,
    required this.windowEnd,
    this.bannerLines = const [],
    required this.onDismissBanner,
    required this.onOpenRecurring,
    this.recurringFlagged = 0,
    required this.onRepeat,
    required this.onEditEntry,
  });

  /// v1.0 Home Page Balance View: 'net' (period net flow, the
  /// original hero) or 'accounts' (sum of latest SMS balances).
  final String balanceView;

  /// v1.0 Balance privacy: account balances render masked.
  final bool balancesHidden;
  final VoidCallback onRevealBalances;

  /// v1.0: current custom-month window for the budget check-in.
  final DateTime windowStart;
  final DateTime windowEnd;

  @override
  Widget build(BuildContext context) {
    var income = 0.0, expenses = 0.0;
    for (final e in periodEntries) {
      if (e.txn.direction == TxnDirection.debit) {
        expenses += e.txn.amount;
      } else {
        income += e.txn.amount;
      }
    }
    final net = income - expenses;
    final rate = income > 0 ? net / income : 0.0;
    final rateLabel = income <= 0
        ? 'No income in this period'
        : rate >= 0.5
        ? 'Healthy pace'
        : rate < 0.2
        ? 'Tight'
        : 'Steady';

    final recent = [...entries]
      ..sort((a, b) => b.txn.receivedAt.compareTo(a.txn.receivedAt));

    // Budget check-in: current-month spend per raw category, top 4
    // budget rows by spend (caps order breaks ties). v1.0: "month"
    // is the custom window from the First Day of the Month setting
    // (the calendar month when the start day is 1).
    final now = DateTime.now();
    final spentByCat = <String, double>{};
    for (final e in entries) {
      if (e.txn.direction != TxnDirection.debit) continue;
      final at = e.txn.receivedAt;
      if (at.isBefore(windowStart) || !at.isBefore(windowEnd)) continue;
      final cat = e.category;
      spentByCat[cat] = (spentByCat[cat] ?? 0) + e.txn.amount;
    }

    // v1.0 hero: 'accounts' view shows the sum of latest balances
    // when any account exists, else falls back to the net flow.
    final accountsTotal = accounts.fold<double>(0, (s, a) => s + a.balance);
    final heroIsAccounts = balanceView == 'accounts' && accounts.isNotEmpty;
    final heroAmount = heroIsAccounts ? accountsTotal : net;
    final checkIn = budgetRows(caps, spentByCat)
      ..sort((a, b) => b.spent.compareTo(a.spent));

    return ListView(
      padding: _pagePadding,
      children: [
        Text(
          '${greetingFor(now)} 👋',
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 14),
        ),
        const SizedBox(height: 4),
        Text('Your money, in control.', style: KanakkuTheme.serif(size: 27)),
        // v1.1 budget-alert banner (spec §4.4): today's crossings
        // plus suppressed ones, until dismissed.
        if (bannerLines.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFFDEFD2),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: Color(0xFFB45309),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Budget alert',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      for (final line in bannerLines)
                        Text(line, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onDismissBanner,
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            _PeriodSelector(period: period, onChanged: onPeriodChanged),
          ],
        ),
        const SizedBox(height: 14),
        // ---- Hero: TOTAL BALANCE ----------------------------------
        Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [KanakkuTheme.tealHero, KanakkuTheme.tealDark],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                heroIsAccounts ? 'TOTAL BALANCE · ACCOUNTS' : 'TOTAL BALANCE',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                KanakkuTheme.inr(heroAmount),
                style: KanakkuTheme.serif(size: 36, color: Colors.white),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '↗ Income',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          KanakkuTheme.inr(income),
                          style: KanakkuTheme.serif(
                            size: 19,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '↘ Expenses',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          KanakkuTheme.inr(expenses),
                          style: KanakkuTheme.serif(
                            size: 19,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // ---- 2×2 stat grid -----------------------------------------
        Row(
          children: [
            Expanded(
              child: _StatCard(
                title: 'Net cash flow',
                value: KanakkuTheme.inr(net),
                sub: net >= 0
                    ? 'Positive balance this period'
                    : 'Spending above income',
                filled: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                title: 'Total income',
                value: KanakkuTheme.inr(income),
                sub: '↑ Inflows',
                subColor: KanakkuTheme.credit,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                title: 'Total expenses',
                value: KanakkuTheme.inr(expenses),
                sub: '↓ Outflows',
                subColor: KanakkuTheme.debit,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                title: 'Savings rate',
                value: '${(rate * 100).round()}%',
                sub: rateLabel,
                subColor: KanakkuTheme.teal,
                progress: rate.clamp(0, 1).toDouble(),
              ),
            ),
          ],
        ),
        if (!usingReal) ...[
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: KanakkuTheme.tealSoft,
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: CircleAvatar(
                    radius: 4,
                    backgroundColor: KanakkuTheme.teal,
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Showing sample data. Turn on SMS access below to see your real spending.',
                    style: TextStyle(fontSize: 13, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        // ---- Today + capture chips ---------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Today', style: KanakkuTheme.serif(size: 16)),
                    ),
                    IconButton(
                      onPressed: onTestSummary,
                      icon: const Icon(
                        Icons.notifications_active_outlined,
                        size: 20,
                      ),
                      tooltip: 'Send test summary',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                Text(
                  KanakkuTheme.inr(summary.todaySpend),
                  style: KanakkuTheme.serif(size: 26),
                ),
                const SizedBox(height: 2),
                Text(
                  '${summary.todayCount} expense${summary.todayCount == 1 ? '' : 's'} today'
                  '${summary.topCategory != null ? ' · Top: ${summary.topCategory}' : ''}'
                  ' · Month so far ${KanakkuTheme.inr(summary.monthSpend)}',
                  style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  'A summary like this arrives at 9 PM every day.',
                  style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _CaptureChip(
                      icon: Icons.sms_outlined,
                      label: smsOn ? 'SMS on' : 'SMS off — tap',
                      on: smsOn,
                      onTap: onEnableSms,
                    ),
                    _CaptureChip(
                      icon: Icons.notifications_outlined,
                      label: notifOn ? 'Alerts on' : 'Alerts off — tap',
                      on: notifOn,
                      onTap: onEnableNotif,
                    ),
                    _CaptureChip(
                      icon: Icons.refresh,
                      label: 'Sync',
                      on: true,
                      onTap: onRefresh,
                    ),
                    // v1.1 (spec §3.1): Recurring shortcut chip.
                    _CaptureChip(
                      icon: Icons.repeat,
                      label: recurringFlagged > 0
                          ? 'Recurring · $recurringFlagged to review'
                          : 'Recurring',
                      on: true,
                      onTap: onOpenRecurring,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (accounts.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('Accounts', style: KanakkuTheme.serif(size: 17)),
          const SizedBox(height: 2),
          Text(
            'Latest balance each bank reported by SMS.',
            style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
          ),
          const SizedBox(height: 8),
          ...accounts.map(
            (a) => Card(
              child: ListTile(
                leading: Container(
                  height: 40,
                  width: 40,
                  decoration: BoxDecoration(
                    color: KanakkuTheme.tealSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.account_balance_outlined,
                    color: KanakkuTheme.teal,
                    size: 20,
                  ),
                ),
                title: Text(
                  '${a.bank} ··${a.last4}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('Updated ${_fmtDay(a.asOf)}'),
                // v1.0 Balance privacy: masked until revealed.
                trailing: balancesHidden
                    ? InkWell(
                        onTap: onRevealBalances,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('₹•••', style: KanakkuTheme.serif(size: 16)),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.visibility_off_outlined,
                              size: 16,
                              color: KanakkuTheme.inkSoft,
                            ),
                          ],
                        ),
                      )
                    : Text(
                        KanakkuTheme.inr(a.balance),
                        style: KanakkuTheme.serif(size: 16),
                      ),
              ),
            ),
          ),
        ],
        if (bills.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('Card bills due', style: KanakkuTheme.serif(size: 17)),
          const SizedBox(height: 8),
          ...bills.map((b) => _BillTile(bill: b)),
        ],
        // ---- Budget check-in ---------------------------------------
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Budget check-in',
                            style: KanakkuTheme.serif(size: 17),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Know how much room you have left.',
                            style: TextStyle(
                              color: KanakkuTheme.inkSoft,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: onManageBudgets,
                      child: const Text(
                        'Manage budgets ›',
                        style: TextStyle(
                          color: KanakkuTheme.teal,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ...checkIn
                    .take(4)
                    .map(
                      (r) => _BudgetCheckInRow(
                        row: r,
                        onEdit: () => onEditBudget(r.category),
                      ),
                    ),
              ],
            ),
          ),
        ),
        // ---- Statement upload ---------------------------------------
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      height: 42,
                      width: 42,
                      decoration: BoxDecoration(
                        color: KanakkuTheme.tealSoft,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.upload_file_outlined,
                        color: KanakkuTheme.teal,
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Bank statement',
                            style: KanakkuTheme.serif(size: 16),
                          ),
                          Text(
                            'Upload a CSV statement and see where it all went.',
                            style: TextStyle(
                              color: KanakkuTheme.inkSoft,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: KanakkuTheme.teal,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: onUploadStatement,
                        child: const Text('Upload bank statement'),
                      ),
                    ),
                    if (hasStatement) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: KanakkuTheme.teal,
                            side: const BorderSide(color: KanakkuTheme.teal),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: onOpenAnalysis,
                          child: const Text('View analysis'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        // ---- Recent transactions ------------------------------------
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Text(
                'Recent transactions',
                style: KanakkuTheme.serif(size: 18),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: KanakkuTheme.teal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 9,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: onViewAll,
              child: const Text('View all'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: recent.isEmpty
                ? const _EmptyTxns()
                : Column(
                    children: [
                      for (var i = 0; i < recent.take(5).length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _TxnRowPlain(
                          entry: recent[i],
                          onRemove: () => onRemove(recent[i]),
                          onSplit: () => onSplit(recent[i]),
                          onRepeat: () => onRepeat(recent[i]),
                          onEdit: recent[i].txn.source == TxnSource.manual
                              ? () => onEditEntry(recent[i])
                              : null,
                        ),
                      ],
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 16),
        _TealButton(label: '+  Add transaction', onPressed: onAdd),
      ],
    );
  }
}

/// One Budget check-in row: icon chip + name, "₹980 of ₹5.0k",
/// progress bar, then "₹4.0k remaining" / "20% used · Edit".
class _BudgetCheckInRow extends StatelessWidget {
  final BudgetRow row;
  final VoidCallback onEdit;
  const _BudgetCheckInRow({required this.row, required this.onEdit});
  @override
  Widget build(BuildContext context) {
    final display = displayCategory(row.category);
    final (icon, color, chip) = _catStyle(display);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                height: 38,
                width: 38,
                decoration: BoxDecoration(
                  color: chip,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: color, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  display,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                KanakkuTheme.inrCompact(row.spent),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                ' of ${KanakkuTheme.inrCompact(row.cap)}',
                style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: row.fraction.clamp(0, 1).toDouble(),
              minHeight: 7,
              backgroundColor: const Color(0xFFEDF1F0),
              color: row.over ? KanakkuTheme.debit : KanakkuTheme.teal,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  row.remaining >= 0
                      ? '${KanakkuTheme.inrCompact(row.remaining)} remaining'
                      : '${KanakkuTheme.inrCompact(-row.remaining)} over budget',
                  style: TextStyle(
                    color: row.over ? KanakkuTheme.debit : KanakkuTheme.inkSoft,
                    fontSize: 12,
                  ),
                ),
              ),
              Text(
                '${row.percentUsed}% used',
                style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onEdit,
                child: const Text(
                  'Edit',
                  style: TextStyle(
                    color: KanakkuTheme.teal,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BillTile extends StatelessWidget {
  final CardBill bill;
  const _BillTile({required this.bill});
  @override
  Widget build(BuildContext context) {
    final days = bill.daysRemaining();
    final (chipText, chipColor) = switch (days) {
      null => ('Date not in SMS', KanakkuTheme.inkSoft),
      < 0 => ('Overdue by ${-days}d', KanakkuTheme.debit),
      0 => ('Due today', KanakkuTheme.debit),
      <= 3 => ('${days}d left', KanakkuTheme.debit),
      <= 7 => ('${days}d left', KanakkuTheme.orange),
      _ => ('${days}d left', KanakkuTheme.inkSoft),
    };
    final due = bill.dueDate;
    return Card(
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: KanakkuTheme.orangeSoft,
          child: Icon(
            Icons.credit_card_outlined,
            color: KanakkuTheme.orange,
            size: 20,
          ),
        ),
        title: Text(
          '${bill.bankHint ?? 'Card'}${bill.cardLast4 != null ? ' ··${bill.cardLast4}' : ''}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          'Total ${KanakkuTheme.inr(bill.totalDue)}'
          '${bill.minDue != null ? ' · Min ${KanakkuTheme.inr(bill.minDue!)}' : ''}'
          '${due != null ? ' · Due ${_fmtDay(due)}' : ''}',
        ),
        trailing: Chip(
          label: Text(
            chipText,
            style: TextStyle(
              fontSize: 11,
              color: chipColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          backgroundColor: const Color(0xFFF5F5F4),
          side: BorderSide.none,
        ),
      ),
    );
  }
}

class _CaptureChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _CaptureChip({
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: Icon(
      icon,
      size: 16,
      color: on ? KanakkuTheme.savings : KanakkuTheme.inkSoft,
    ),
    label: Text(label, style: const TextStyle(fontSize: 12)),
    backgroundColor: on ? const Color(0xFFF0FDF4) : const Color(0xFFF5F5F4),
    side: BorderSide.none,
    onPressed: onTap,
  );
}

/// Transaction row in the v0.7 reference style — pastel category
/// icon chip, merchant name + note, category in grey on the right
/// above the amount. Used inside the Home "Recent transactions"
/// card and the Transactions list card. Same ⋮ actions as before.
class _TxnRowPlain extends StatelessWidget {
  final _Entry entry;
  final VoidCallback? onRemove;
  final VoidCallback? onSplit;

  /// v1.1: "Repeat this" (create a recurring rule from this entry)
  /// and "Edit entry" (manual entries only) in the ⋮ menu.
  final VoidCallback? onRepeat;
  final VoidCallback? onEdit;
  const _TxnRowPlain({
    required this.entry,
    this.onRemove,
    this.onSplit,
    this.onRepeat,
    this.onEdit,
  });
  @override
  Widget build(BuildContext context) {
    final t = entry.txn;
    final isDebit = t.direction == TxnDirection.debit;
    final display = displayCategory(entry.category);
    final (icon, color, chip) = _catStyle(display);
    // v1.0: manual rows show their payment mode ("UPI · Food
    // Delivery"); the note still wins when one was written.
    final subtitle = (entry.note != null && entry.note!.isNotEmpty)
        ? entry.note!
        : entry.mode != null
        ? '${entry.mode} · $display'
        : t.source == TxnSource.statement
        ? 'Statement · ${_fmtDay(t.receivedAt)}'
        : '${t.bankHint ?? 'Account'} ${t.accountLast4 ?? ''} · ${entry.bucket.name}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            height: 42,
            width: 42,
            decoration: BoxDecoration(
              color: chip,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              t.source == TxnSource.statement
                  ? Icons.account_balance_outlined
                  : icon,
              color: color,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // v1.0: tag chip under the subtitle.
                if (entry.tag != null) ...[
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: KanakkuTheme.tealSoft,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '#${entry.tag}',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: KanakkuTheme.tealDark,
                      ),
                    ),
                  ),
                ],
                // v1.1 (spec §3.7): recurring-generated entries
                // carry the ↻ tag.
                if (entry.origin == 'recurring') ...[
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFDEFD2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '↻ Recurring',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFB45309),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${isDebit ? '-' : '+'}${KanakkuTheme.inr(t.amount)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: isDebit ? KanakkuTheme.debit : KanakkuTheme.credit,
                ),
              ),
              Text(
                display,
                style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 11),
              ),
            ],
          ),
          if (onRemove != null || onSplit != null || onRepeat != null || onEdit != null)
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert,
                size: 20,
                color: KanakkuTheme.inkSoft,
              ),
              tooltip: 'Transaction options',
              onSelected: (v) {
                if (v == 'remove') onRemove!();
                if (v == 'split') onSplit!();
                if (v == 'repeat') onRepeat!();
                if (v == 'edit') onEdit!();
              },
              itemBuilder: (_) => [
                if (onRepeat != null)
                  const PopupMenuItem(
                    value: 'repeat',
                    child: Row(
                      children: [
                        Icon(
                          Icons.repeat,
                          size: 18,
                          color: KanakkuTheme.teal,
                        ),
                        SizedBox(width: 8),
                        Text('Repeat this'),
                      ],
                    ),
                  ),
                if (onEdit != null)
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: KanakkuTheme.teal,
                        ),
                        SizedBox(width: 8),
                        Text('Edit entry'),
                      ],
                    ),
                  ),
                if (onSplit != null && isDebit)
                  const PopupMenuItem(
                    value: 'split',
                    child: Row(
                      children: [
                        Icon(
                          Icons.call_split_outlined,
                          size: 18,
                          color: KanakkuTheme.teal,
                        ),
                        SizedBox(width: 8),
                        Text('Split bill'),
                      ],
                    ),
                  ),
                if (onRemove != null)
                  const PopupMenuItem(
                    value: 'remove',
                    child: Row(
                      children: [
                        Icon(
                          Icons.block_outlined,
                          size: 18,
                          color: KanakkuTheme.debit,
                        ),
                        SizedBox(width: 8),
                        Text('Remove — not an expense'),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Transactions extends StatefulWidget {
  final List<_Entry> entries;
  final void Function(_Entry) onRemove;
  final void Function(_Entry) onSplit;
  final int removedCount;
  final VoidCallback onOpenRemoved;
  final VoidCallback onAdd;
  final VoidCallback onUploadStatement;

  /// v1.1: row long-press/menu actions (see _TxnRowPlain).
  final void Function(_Entry) onRepeat;
  final void Function(_Entry) onEditEntry;
  const _Transactions({
    required this.entries,
    required this.onRemove,
    required this.onSplit,
    required this.removedCount,
    required this.onOpenRemoved,
    required this.onAdd,
    required this.onUploadStatement,
    required this.onRepeat,
    required this.onEditEntry,
  });
  @override
  State<_Transactions> createState() => _TransactionsState();
}

class _TransactionsState extends State<_Transactions> {
  /// v1.0 tag filter: null = All.
  String? _tagFilter;

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.entries]
      ..sort((a, b) => b.txn.receivedAt.compareTo(a.txn.receivedAt));
    final tags = distinctTags(widget.entries.map((e) => e.tag));
    if (_tagFilter != null && !tags.contains(_tagFilter)) _tagFilter = null;
    final visible = sorted
        .where((e) => tagFilterPasses(e.tag, _tagFilter))
        .toList();
    return ListView(
      padding: _pagePadding,
      children: [
        Text('Transactions', style: KanakkuTheme.serif(size: 28)),
        const SizedBox(height: 4),
        Text(
          'Your income and spending, all in one place.',
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 14),
        ),
        const SizedBox(height: 18),
        _TealButton(label: '+  Add transaction', onPressed: widget.onAdd),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: KanakkuTheme.teal,
              side: const BorderSide(color: KanakkuTheme.teal),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: widget.onUploadStatement,
            icon: const Icon(Icons.upload_file_outlined, size: 19),
            label: const Text(
              'Upload bank statement',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                'OTP and promo messages are filtered out automatically.',
                style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
              ),
            ),
            TextButton.icon(
              onPressed: widget.removedCount > 0 ? widget.onOpenRemoved : null,
              icon: const Icon(Icons.block_outlined, size: 16),
              label: Text('Removed (${widget.removedCount})'),
            ),
          ],
        ),
        // v1.0: tag filter row (only when tags exist).
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _tagFilter == null,
                  selectedColor: KanakkuTheme.tealSoft,
                  onSelected: (_) => setState(() => _tagFilter = null),
                ),
                for (final t in tags) ...[
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text('#$t'),
                    selected: _tagFilter == t,
                    selectedColor: KanakkuTheme.tealSoft,
                    onSelected: (_) => setState(() => _tagFilter = t),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 6),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: sorted.isEmpty
                ? const _EmptyTxns()
                : visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Center(
                      child: Text(
                        'No transactions tagged #$_tagFilter',
                        style: TextStyle(color: KanakkuTheme.inkSoft),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < visible.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _TxnRowPlain(
                          entry: visible[i],
                          onRemove: () => widget.onRemove(visible[i]),
                          onSplit: () => widget.onSplit(visible[i]),
                          onRepeat: () => widget.onRepeat(visible[i]),
                          onEdit: visible[i].txn.source == TxnSource.manual
                              ? () => widget.onEditEntry(visible[i])
                              : null,
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// Budgets tab (v0.7, reference layout): one white card per budget
/// category — serif name, "₹X spent / ₹Y budget", thin progress bar
/// (red over 100%). Budgets are EDITABLE (tap a card) and persist
/// natively. The 50/30/20 salary split rides along as a slim card.
class _Budgets extends StatelessWidget {
  final List<_Entry> entries;
  final Map<String, double> caps;
  final void Function(String) onEditBudget;

  /// v1.0: the budget month window (First Day of the Month); the
  /// calendar month when the start day is 1.
  final DateTime windowStart;
  final DateTime windowEnd;

  /// v1.1 (spec §4.4): thresholds already fired this month per
  /// category — renders the fired-state dot on the row.
  final Map<String, Set<int>> firedByCategory;
  const _Budgets({
    required this.entries,
    required this.caps,
    required this.onEditBudget,
    required this.windowStart,
    required this.windowEnd,
    this.firedByCategory = const {},
  });
  @override
  Widget build(BuildContext context) {
    var needsSpent = 0.0, wantsSpent = 0.0, saved = 0.0;
    final spentByCat = <String, double>{};
    for (final e in entries) {
      if (e.txn.direction != TxnDirection.debit) continue;
      final at = e.txn.receivedAt;
      if (at.isBefore(windowStart) || !at.isBefore(windowEnd)) continue;
      switch (e.bucket) {
        case Bucket.needs:
          needsSpent += e.txn.amount;
        case Bucket.wants:
          wantsSpent += e.txn.amount;
        case Bucket.savings:
          saved += e.txn.amount;
      }
      final cat = e.category;
      spentByCat[cat] = (spentByCat[cat] ?? 0) + e.txn.amount;
    }
    final rows = budgetRows(caps, spentByCat);
    Widget splitRow(String label, double spent, double cap, Color color) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              CircleAvatar(radius: 5, backgroundColor: color),
              const SizedBox(width: 10),
              Expanded(child: Text(label)),
              Text(
                '${KanakkuTheme.inr(spent)} of ${KanakkuTheme.inr(cap)}',
                style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
              ),
            ],
          ),
        );
    return ListView(
      padding: _pagePadding,
      children: [
        Text('Budgets', style: KanakkuTheme.serif(size: 28)),
        const SizedBox(height: 4),
        Text(
          'Keep spending within your monthly plan.',
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 14),
        ),
        const SizedBox(height: 4),
        // v1.1 (spec §4.5): the honesty line, verbatim, wherever
        // alerts are described.
        Text(
          budgetAlertHonestyLine,
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
        ),
        const SizedBox(height: 18),
        ...rows.map(
          (r) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => onEditBudget(r.category),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              r.category,
                              style: KanakkuTheme.serif(size: 18),
                            ),
                          ),
                          // v1.1 (spec §4.4): fired-state dot when
                          // this month's 80% or 100% alert fired.
                          if ((firedByCategory[r.category] ?? const {})
                              .isNotEmpty)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Icon(
                                Icons.circle,
                                size: 9,
                                color: Color(0xFFB45309),
                              ),
                            ),
                          const Text(
                            'Edit',
                            style: TextStyle(
                              color: KanakkuTheme.teal,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${KanakkuTheme.inr(r.spent)} spent  /  ${KanakkuTheme.inr(r.cap)} budget · ${r.percentUsed}% used',
                        style: TextStyle(
                          color: KanakkuTheme.inkSoft,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // v1.1 (spec §4.4): progress bar with an 80%
                      // tick mark.
                      LayoutBuilder(
                        builder: (ctx, box) => Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: r.fraction.clamp(0, 1).toDouble(),
                                minHeight: 6,
                                backgroundColor: const Color(0xFFE4E9E7),
                                color: r.over
                                    ? KanakkuTheme.debit
                                    : KanakkuTheme.teal,
                              ),
                            ),
                            Positioned(
                              left: box.maxWidth * 0.8 - 1,
                              top: 0,
                              child: Container(
                                width: 2,
                                height: 6,
                                color: KanakkuTheme.inkSoft,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (r.over) ...[
                        const SizedBox(height: 6),
                        Text(
                          '${KanakkuTheme.inr(-r.remaining)} over budget',
                          style: const TextStyle(
                            color: KanakkuTheme.debit,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Salary split · 50 / 30 / 20',
                  style: KanakkuTheme.serif(size: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  'Of the ₹35,000 monthly plan, computed live from this month\'s captured transactions.',
                  style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
                ),
                const SizedBox(height: 8),
                splitRow('Needs · 50%', needsSpent, 17500, KanakkuTheme.needs),
                splitRow('Wants · 30%', wantsSpent, 10500, KanakkuTheme.wants),
                splitRow('Savings · 20%', saved, 7000, KanakkuTheme.savings),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Budgets are monthly limits. Tap any card to change its amount — the new limit is saved on this phone.',
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
        ),
      ],
    );
  }
}

(IconData, Color, Color) _catStyle(String name) => switch (name) {
  'Bills & utilities' => (
    Icons.receipt_long_outlined,
    KanakkuTheme.teal,
    const Color(0xFFDFF2EC),
  ),
  'Transport' => (
    Icons.directions_car_outlined,
    const Color(0xFF2F7DE1),
    const Color(0xFFE1EDFD),
  ),
  'Shopping' => (
    Icons.shopping_bag_outlined,
    const Color(0xFFF59E0B),
    const Color(0xFFFDEFD2),
  ),
  'Food & dining' => (
    Icons.restaurant_outlined,
    const Color(0xFF8B5CF6),
    const Color(0xFFECE5FD),
  ),
  'Groceries' => (
    Icons.local_grocery_store_outlined,
    const Color(0xFFF43F5E),
    const Color(0xFFFDE4EC),
  ),
  'Health' => (
    Icons.favorite_outline,
    const Color(0xFF10B981),
    const Color(0xFFDFF7EC),
  ),
  'Subscriptions' => (
    Icons.subscriptions_outlined,
    const Color(0xFF6366F1),
    const Color(0xFFE4E6FD),
  ),
  'Entertainment' => (
    Icons.movie_outlined,
    const Color(0xFFEC4899),
    const Color(0xFFFCE0F0),
  ),
  'Investments' => (
    Icons.trending_up,
    KanakkuTheme.savings,
    const Color(0xFFDFF7E8),
  ),
  _ => (
    Icons.category_outlined,
    const Color(0xFF94A3B8),
    const Color(0xFFEDF1F5),
  ),
};

/// Insights (v0.7, reference layout): serif title + period
/// selector, four stacked stat cards (Total income / Total
/// expenses / Net savings / Transactions recorded), then the v0.6
/// "Spending overview" weekly bars + "Where it goes" cards, the
/// statement-analysis entry, and the big export buttons.
class _Insights extends StatefulWidget {
  final List<_Entry> entries;
  final PeriodSel period;
  final void Function(PeriodSel) onPeriodChanged;
  final VoidCallback onExportCsv;
  final VoidCallback onExportPdf;
  final bool hasStatement;
  final VoidCallback onOpenAnalysis;

  /// v1.0 First Day of the Month: when > 1 the chart and totals are
  /// measured inside the custom month window instead of the
  /// calendar month.
  final int monthStartDay;
  const _Insights({
    required this.entries,
    required this.period,
    required this.onPeriodChanged,
    required this.onExportCsv,
    required this.onExportPdf,
    required this.hasStatement,
    required this.onOpenAnalysis,
    this.monthStartDay = 1,
  });
  @override
  State<_Insights> createState() => _InsightsState();
}

class _InsightsState extends State<_Insights> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final (start, end) = periodRange(widget.period, now, widget.monthStartDay);
    final customMonth = widget.monthStartDay > 1;
    bool inRange(DateTime at) => !at.isBefore(start) && at.isBefore(end);

    final txns = [
      for (final e in widget.entries)
        InsightTxn(
          at: e.txn.receivedAt,
          amount: e.txn.amount,
          isDebit: e.txn.direction == TxnDirection.debit,
          category: e.category,
          bucket: e.bucket,
        ),
    ];

    // Period stat cards.
    var income = 0.0, expenses = 0.0, count = 0;
    for (final e in widget.entries) {
      if (!inRange(e.txn.receivedAt)) continue;
      count++;
      if (e.txn.direction == TxnDirection.debit) {
        expenses += e.txn.amount;
      } else {
        income += e.txn.amount;
      }
    }

    // Spending-overview chart month: the period's month; for
    // All time, the month of the most recent spend.
    final chartMonth = switch (widget.period) {
      PeriodSel.thisMonth => DateTime(now.year, now.month),
      PeriodSel.lastMonth => DateTime(now.year, now.month - 1),
      PeriodSel.allTime => () {
        DateTime latest = DateTime(now.year, now.month);
        for (final t in txns) {
          if (t.isDebit && t.at.isAfter(latest)) {
            latest = DateTime(t.at.year, t.at.month);
          }
        }
        return latest;
      }(),
    };
    // v1.0 custom month: bucket the period window into 7-day weeks
    // from its start; the calendar path below is untouched.
    final weeks = customMonth && widget.period != PeriodSel.allTime
        ? weeklyTotalsIn(txns, start, end)
        : weeklyTotals(txns, chartMonth);
    final maxWeek = weeks.fold(0.0, (a, b) => b > a ? b : a);
    final maxWeekIdx = maxWeek > 0 ? weeks.indexOf(maxWeek) : -1;

    // "Where it goes": period range (monthly fast path keeps the
    // v0.6 behaviour for This month).
    final cats = widget.period == PeriodSel.thisMonth && !customMonth
        ? categoryTotals(txns, chartMonth)
        : categoryTotalsIn(txns, start, end);
    final total = widget.period == PeriodSel.thisMonth && !customMonth
        ? monthSpend(txns, chartMonth)
        : spendIn(txns, start, end);
    final shownCats = _showAll ? cats : cats.take(5).toList();

    // 50/30/20 buckets over the selected period (Details) + top leak.
    var needs = 0.0, wants = 0.0, savings = 0.0;
    final wantsByCat = <String, double>{};
    for (final t in txns) {
      if (!t.isDebit || !inRange(t.at)) continue;
      switch (t.bucket) {
        case Bucket.needs:
          needs += t.amount;
        case Bucket.wants:
          wants += t.amount;
          final c = displayCategory(t.category);
          wantsByCat[c] = (wantsByCat[c] ?? 0) + t.amount;
        case Bucket.savings:
          savings += t.amount;
      }
    }
    final leakPool = wantsByCat.isNotEmpty
        ? wantsByCat
        : {for (final c in cats) c.name: c.amount};
    final leak = leakPool.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final labelMonth = customMonth ? start : chartMonth;
    final mm = labelMonth.month.toString().padLeft(2, '0');

    Widget statCard(String label, String value) => Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(value, style: KanakkuTheme.serif(size: 28)),
          ],
        ),
      ),
    );

    return ListView(
      padding: _pagePadding,
      children: [
        Text('Insights', style: KanakkuTheme.serif(size: 28)),
        const SizedBox(height: 4),
        Text(
          'A quick view of your money movement.',
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 14),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            _PeriodSelector(
              period: widget.period,
              onChanged: widget.onPeriodChanged,
            ),
          ],
        ),
        const SizedBox(height: 14),
        statCard('Total income', KanakkuTheme.inr(income)),
        const SizedBox(height: 12),
        statCard('Total expenses', KanakkuTheme.inr(expenses)),
        const SizedBox(height: 12),
        statCard('Net savings', KanakkuTheme.inr(income - expenses)),
        const SizedBox(height: 12),
        statCard('Transactions recorded', '$count'),
        const SizedBox(height: 16),
        // ---- Spending overview (v0.6 card, restyled) ---------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Spending overview',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Your expense pattern through the month',
                            style: TextStyle(
                              color: KanakkuTheme.inkSoft,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      height: 40,
                      width: 40,
                      decoration: BoxDecoration(
                        color: KanakkuTheme.tealSoft,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.show_chart,
                        color: KanakkuTheme.teal,
                        size: 21,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Total spent',
                            style: TextStyle(
                              color: KanakkuTheme.inkSoft,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            KanakkuTheme.inrCompact(
                              monthSpend(txns, chartMonth),
                            ),
                            style: KanakkuTheme.serif(size: 30),
                          ),
                        ],
                      ),
                    ),
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 5,
                          backgroundColor: KanakkuTheme.teal,
                        ),
                        SizedBox(width: 6),
                        Text('Expenses', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 128,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < 5; i++)
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                width: 34,
                                height: maxWeek == 0
                                    ? 6
                                    : 8 + 92 * (weeks[i] / maxWeek),
                                decoration: BoxDecoration(
                                  color: i == maxWeekIdx
                                      ? KanakkuTheme.teal
                                      : KanakkuTheme.tealMint,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(8),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Wk ${i + 1}',
                                style: TextStyle(
                                  color: KanakkuTheme.inkSoft,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 24),
                Row(
                  children: [
                    const CircleAvatar(
                      radius: 4,
                      backgroundColor: KanakkuTheme.teal,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Weekly expense totals',
                        style: TextStyle(
                          color: KanakkuTheme.inkSoft,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text(
                      'INR · ${labelMonth.year}-$mm',
                      style: TextStyle(
                        color: KanakkuTheme.inkSoft,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // ---- Where it goes (v0.6 card, restyled) -------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Where it goes',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Top spending categories',
                            style: TextStyle(
                              color: KanakkuTheme.inkSoft,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (cats.isNotEmpty)
                      TextButton(
                        onPressed: () => setState(() => _showAll = !_showAll),
                        child: Text(
                          _showAll ? 'Hide ›' : 'Details ›',
                          style: const TextStyle(
                            color: KanakkuTheme.teal,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      KanakkuTheme.inrCompact(total),
                      style: KanakkuTheme.serif(size: 28),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'total expenses',
                      style: TextStyle(
                        color: KanakkuTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (cats.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No spending captured in this period yet.',
                      style: TextStyle(color: KanakkuTheme.inkSoft),
                    ),
                  )
                else
                  ...shownCats.map((c) => _CategoryRow(total: c)),
                if (_showAll && cats.isNotEmpty) ...[
                  const Divider(height: 28),
                  const Text(
                    'Plan split · 50 / 30 / 20',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  _Legend(
                    color: KanakkuTheme.needs,
                    label: 'Needs',
                    value: KanakkuTheme.inr(needs),
                  ),
                  _Legend(
                    color: KanakkuTheme.wants,
                    label: 'Wants',
                    value: KanakkuTheme.inr(wants),
                  ),
                  _Legend(
                    color: KanakkuTheme.savings,
                    label: 'Savings',
                    value: KanakkuTheme.inr(savings),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (leak.isNotEmpty)
          Card(
            child: ListTile(
              leading: Container(
                height: 40,
                width: 40,
                decoration: BoxDecoration(
                  color: KanakkuTheme.tealSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: KanakkuTheme.teal,
                  size: 20,
                ),
              ),
              title: Text(
                'Top leak: ${leak.first.key}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${KanakkuTheme.inr(leak.first.value)} out in this period. Check the Budgets tab for the cap.',
              ),
            ),
          ),
        if (widget.hasStatement) ...[
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: Container(
                height: 40,
                width: 40,
                decoration: BoxDecoration(
                  color: KanakkuTheme.tealSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.analytics_outlined,
                  color: KanakkuTheme.teal,
                  size: 20,
                ),
              ),
              title: const Text(
                'Statement analysis',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Totals, top categories and merchants from your imported statement.',
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: KanakkuTheme.teal,
              ),
              onTap: widget.onOpenAnalysis,
            ),
          ),
        ],
        const SizedBox(height: 22),
        Text(
          'Export your transactions as CSV',
          style: KanakkuTheme.serif(size: 19),
        ),
        const SizedBox(height: 12),
        _TealButton(label: 'Export CSV', onPressed: widget.onExportCsv),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: KanakkuTheme.teal,
              side: const BorderSide(color: KanakkuTheme.teal),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: widget.onExportPdf,
            child: const Text(
              'Export PDF',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }
}

/// One "Where it goes" row: pastel icon chip, name, compact amount,
/// grey % share, and a full-width progress bar in the category colour.
class _CategoryRow extends StatelessWidget {
  final CategoryTotal total;
  const _CategoryRow({required this.total});
  @override
  Widget build(BuildContext context) {
    final (icon, bar, chip) = _catStyle(total.name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              color: chip,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: bar, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        total.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      KanakkuTheme.inrCompact(total.amount),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${total.percent}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: KanakkuTheme.inkSoft,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: total.share.clamp(0, 1),
                    minHeight: 7,
                    backgroundColor: bar.withValues(alpha: 0.14),
                    color: bar,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  final String value;
  const _Legend({
    required this.color,
    required this.label,
    required this.value,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        CircleAvatar(radius: 5, backgroundColor: color),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

/// Split-bill sheet (v0.5): type the people's names, pick who paid,
/// equal split by default — or switch on custom amounts.
class _SplitSheet extends StatefulWidget {
  final _Entry entry;
  final void Function(SplitRecord) onSave;
  const _SplitSheet({required this.entry, required this.onSave});
  @override
  State<_SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<_SplitSheet> {
  final List<TextEditingController> _names = [
    TextEditingController(),
    TextEditingController(),
  ];
  final List<TextEditingController> _amounts = [
    TextEditingController(),
    TextEditingController(),
  ];
  final _myAmount = TextEditingController(); // custom share for "You"
  final _payer = TextEditingController(text: kYou);
  bool _includeMe = true;
  bool _custom = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _names) {
      c.dispose();
    }
    for (final c in _amounts) {
      c.dispose();
    }
    _myAmount.dispose();
    _payer.dispose();
    super.dispose();
  }

  List<String> get _people => [
    if (_includeMe) kYou,
    for (final c in _names)
      if (c.text.trim().isNotEmpty) c.text.trim(),
  ];

  void _save() {
    final people = _people;
    final total = widget.entry.txn.amount;
    if (people.length < 2) {
      setState(() => _error = 'Add at least one person besides the payer.');
      return;
    }
    if (people.toSet().length != people.length) {
      setState(() => _error = 'Names must be unique.');
      return;
    }
    final payer = _payer.text.trim().isEmpty ? kYou : _payer.text.trim();
    if (!people.contains(payer)) {
      setState(
        () => _error = 'The payer must be one of the people in the split.',
      );
      return;
    }
    final List<double> amounts;
    if (_custom) {
      // One share field per participant: "You" has its own field,
      // each name row carries its own — pair them by name.
      double parse(TextEditingController c) =>
          double.tryParse(c.text.replaceAll(',', '')) ?? 0;
      final perPerson = <String, double>{};
      if (_includeMe) perPerson[kYou] = parse(_myAmount);
      for (var i = 0; i < _names.length; i++) {
        final n = _names[i].text.trim();
        if (n.isNotEmpty) perPerson[n] = parse(_amounts[i]);
      }
      amounts = [for (final p in people) perPerson[p] ?? 0];
      final sum = amounts.fold(0.0, (a, b) => a + b);
      if ((sum - total).abs() > 0.01) {
        setState(
          () => _error =
              'Shares add up to ${KanakkuTheme.inr(sum)}, but the bill is ${KanakkuTheme.inr(total)}.',
        );
        return;
      }
    } else {
      amounts = equalSplit(total, people.length);
    }
    final now = DateTime.now();
    final split = SplitRecord(
      id: 'split-${fnv1a('${widget.entry.id}|${now.millisecondsSinceEpoch}')}',
      entryId: widget.entry.id,
      label: widget.entry.label,
      total: total,
      payer: payer,
      shares: [
        for (var i = 0; i < people.length; i++)
          SplitShare(
            name: people[i],
            amount: amounts[i],
            settled: people[i] == payer, // payer's own share is done
          ),
      ],
      ts: now.millisecondsSinceEpoch,
    );
    widget.onSave(split);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.entry.txn.amount;
    final people = _people;
    final preview = _custom
        ? null
        : equalSplit(total, people.isEmpty ? 1 : people.length);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Split bill',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.entry.label} · ${KanakkuTheme.inr(total)}',
              style: TextStyle(color: KanakkuTheme.inkSoft),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _payer,
              decoration: const InputDecoration(
                labelText: 'Paid by (name, or You)',
              ),
              onChanged: (_) => setState(() {}),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include me in the split'),
              value: _includeMe,
              onChanged: (v) => setState(() => _includeMe = v),
            ),
            if (_custom && _includeMe)
              Row(
                children: [
                  const Expanded(child: Text('You')),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _myAmount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        prefixText: '₹ ',
                        labelText: 'Share',
                      ),
                    ),
                  ),
                ],
              ),
            for (var i = 0; i < _names.length; i++)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _names[i],
                      decoration: InputDecoration(
                        labelText: 'Person ${i + 1} name',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (_custom) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _amounts[i],
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          prefixText: '₹ ',
                          labelText: 'Share',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _names.add(TextEditingController());
                  _amounts.add(TextEditingController());
                }),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add person'),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Custom amounts'),
              subtitle: const Text('Off = equal split for everyone'),
              value: _custom,
              onChanged: (v) => setState(() => _custom = v),
            ),
            if (!_custom && people.length >= 2)
              Text(
                'Each person pays ${KanakkuTheme.inr(preview!.first)} (${people.length} ways)',
                style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: KanakkuTheme.debit, fontSize: 13),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: KanakkuTheme.orange,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _save,
                child: const Text(
                  'Save split',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Splits tab (v0.5): who owes whom, per-split shares, settle actions.
class _SplitsPage extends StatelessWidget {
  final List<SplitRecord> splits;
  final void Function(String splitId, String name) onToggleShare;
  final void Function(String splitId) onDelete;
  const _SplitsPage({
    required this.splits,
    required this.onToggleShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final balances = netBalances(splits);
    final balanceRows =
        balances.entries.where((e) => e.value.abs() >= 0.005).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return ListView(
      padding: _pagePadding,
      children: [
        Text('Split bills', style: KanakkuTheme.serif(size: 28)),
        const SizedBox(height: 4),
        Text(
          'Split any expense from the ⋮ menu on a transaction. Settled shares drop out of the balances.',
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Balances',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (balanceRows.isEmpty)
                  Text(
                    'All settled. Nobody owes anybody.',
                    style: TextStyle(color: KanakkuTheme.inkSoft),
                  )
                else
                  ...balanceRows.map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.value > 0
                                  ? '${e.key} owes you'
                                  : 'You owe ${e.key}',
                            ),
                          ),
                          Text(
                            KanakkuTheme.inr(e.value.abs()),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: e.value > 0
                                  ? KanakkuTheme.credit
                                  : KanakkuTheme.debit,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (splits.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(
                Icons.call_split_outlined,
                color: KanakkuTheme.orange,
              ),
              title: Text('No splits yet'),
              subtitle: Text('Open any expense, tap ⋮ → Split bill.'),
            ),
          )
        else
          ...splits.map(
            (s) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${s.label} · ${KanakkuTheme.inr(s.total)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (s.allSettled)
                          const Chip(
                            label: Text(
                              'Settled',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            backgroundColor: Color(0xFFF0FDF4),
                            side: BorderSide.none,
                          ),
                        IconButton(
                          onPressed: () => onDelete(s.id),
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: 'Delete split',
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    Text(
                      'Paid by ${s.payer} · ${_fmtDay(DateTime.fromMillisecondsSinceEpoch(s.ts))}',
                      style: TextStyle(
                        color: KanakkuTheme.inkSoft,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...s.shares.map(
                      (sh) => Row(
                        children: [
                          Expanded(
                            child: Text(
                              sh.name == s.payer
                                  ? '${sh.name} (paid)'
                                  : sh.name,
                              style: TextStyle(
                                color: sh.settled
                                    ? KanakkuTheme.inkSoft
                                    : KanakkuTheme.ink,
                                decoration: sh.settled
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          Text(
                            KanakkuTheme.inr(sh.amount),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 8),
                          if (sh.name != s.payer)
                            TextButton(
                              onPressed: () => onToggleShare(s.id, sh.name),
                              child: Text(sh.settled ? 'Undo' : 'Settle'),
                            )
                          else
                            const SizedBox(width: 64),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Settings (v0.5): app-lock PIN management + daily summary controls.
/// Settings (v1.0 "Options pack" rebuild): profile header,
/// Preferences, Appearance, Notifications, Backup/Restore/Export,
/// Security, Categories shortcut, Support & Feedback, More, and
/// the Danger Zone. Every row is functional — what you see here
/// is wired to a real setting, store or flow. Cloud sync and
/// G-Drive auto-backup deliberately do NOT appear: they arrive
/// with the Firebase phase, and a dead row would be a lie.
class _SettingsPage extends StatefulWidget {
  final CaptureService capture;
  final KanakkuSettings settings;
  final Future<void> Function(KanakkuSettings) onSettingsChanged;
  final String summaryLine;
  final Future<void> Function() onBackup;
  final Future<void> Function() onRestore;
  final VoidCallback onExport;
  final VoidCallback onImportStatement;
  final VoidCallback onOpenCategories;
  final Future<void> Function() onWipeData;
  final void Function(int) onJumpTab;
  const _SettingsPage({
    required this.capture,
    required this.settings,
    required this.onSettingsChanged,
    required this.summaryLine,
    required this.onBackup,
    required this.onRestore,
    required this.onExport,
    required this.onImportStatement,
    required this.onOpenCategories,
    required this.onWipeData,
    required this.onJumpTab,
  });
  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late KanakkuSettings _s = widget.settings;
  bool? _pinSet;

  /// v1.1: last biometric probe result (spec §5.2 enum as string).
  String? _bioStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final set = await widget.capture.pinIsSet();
    if (!mounted) return;
    setState(() => _pinSet = set);
    // v1.1 (spec §2.4): the biometric flag is force-false when no
    // PIN is set — biometrics are only ever a convenience on top
    // of the PIN gate.
    if (!set && widget.settings.biometricUnlock) {
      await _update(_s.copyWith(biometricUnlock: false));
    }
    if (set) {
      final status = await widget.capture.biometricStatus();
      if (!mounted) return;
      setState(() => _bioStatus = status);
    }
  }

  Future<void> _update(KanakkuSettings next) async {
    setState(() => _s = next);
    await widget.onSettingsChanged(next);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- pickers ----------------------------------------------------

  Future<String?> _pickChoice(
    String title,
    List<String> options,
    String current,
  ) => showModalBottomSheet<String>(
    context: context,
    backgroundColor: KanakkuTheme.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(title, style: KanakkuTheme.serif(size: 18)),
          ),
          for (final o in options)
            ListTile(
              title: Text(o),
              trailing: o == current
                  ? const Icon(Icons.check, color: KanakkuTheme.teal)
                  : null,
              onTap: () => Navigator.pop(ctx, o),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  Future<void> _editName() async {
    final ctl = TextEditingController(text: _s.profileName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (name != null && name.isNotEmpty) {
      await _update(_s.copyWith(profileName: name));
    }
  }

  Future<void> _pickReminderTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _s.dailyReminderHour,
        minute: _s.dailyReminderMinute,
      ),
    );
    if (t != null) {
      await _update(
        _s.copyWith(dailyReminderHour: t.hour, dailyReminderMinute: t.minute),
      );
    }
  }

  // ---- PIN (kept from the previous Settings) ----------------------

  Future<String?> _askPin(String title) async {
    final ctrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          autofocus: true,
          maxLength: 6,
          decoration: const InputDecoration(
            hintText: '4–6 digits',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (pin == null) return null;
    if (!isValidPinFormat(pin)) {
      _toast('PIN must be 4–6 digits.');
      return null;
    }
    return pin;
  }

  Future<void> _setOrChange() async {
    if (_pinSet == true) {
      final current = await _askPin('Enter current PIN');
      if (current == null) return;
      final res = await widget.capture.pinVerify(current);
      if (!res.ok) {
        _toast(
          res.lockoutSeconds > 0
              ? 'Too many wrong PINs — try again in ${res.lockoutSeconds}s'
              : 'Current PIN is wrong.',
        );
        return;
      }
    }
    final next = await _askPin(_pinSet == true ? 'Enter new PIN' : 'Set a PIN');
    if (next == null) return;
    await widget.capture.pinSet(next);
    if (!mounted) return;
    setState(() => _pinSet = true);
    _toast('App lock is on. It will ask for the PIN at launch.');
  }

  Future<void> _disable() async {
    final current = await _askPin('Enter PIN to disable the lock');
    if (current == null) return;
    final res = await widget.capture.pinVerify(current);
    if (!res.ok) {
      _toast(
        res.lockoutSeconds > 0
            ? 'Too many wrong PINs — try again in ${res.lockoutSeconds}s'
            : 'PIN is wrong — lock stays on.',
      );
      return;
    }
    await widget.capture.pinClear();
    if (!mounted) return;
    setState(() => _pinSet = false);
    // v1.1 (spec §5.3): clearing the PIN anywhere forces the
    // biometric flag off with it.
    if (_s.biometricUnlock) {
      await _update(_s.copyWith(biometricUnlock: false));
    }
  }

  /// v1.1 (spec §5.3): enabling biometric unlock requires, in
  /// order, a counted PIN verification, a live probe that returns
  /// 'available', and one successful prompt — only then is the
  /// flag persisted. Disabling requires a counted PIN verification.
  Future<void> _toggleBiometric(bool v) async {
    final pin = await _askPin(
      v
          ? 'Enter PIN to enable fingerprint unlock'
          : 'Enter PIN to disable fingerprint unlock',
    );
    if (pin == null) return;
    final res = await widget.capture.pinVerify(pin);
    if (!res.ok) {
      _toast(
        res.lockoutSeconds > 0
            ? 'Too many wrong PINs — try again in ${res.lockoutSeconds}s'
            : 'PIN is wrong — no change made.',
      );
      return;
    }
    if (!v) {
      await _update(_s.copyWith(biometricUnlock: false));
      _toast('Fingerprint / face unlock is off.');
      return;
    }
    final status = await widget.capture.biometricStatus();
    if (!mounted) return;
    setState(() => _bioStatus = status);
    if (status != 'available') {
      _toast(_bioStatusMessage(status));
      return;
    }
    final ok = await widget.capture.biometricPrompt();
    if (!mounted) return;
    if (!ok) {
      _toast('Biometric check did not succeed — unlock stays off.');
      return;
    }
    await _update(_s.copyWith(biometricUnlock: true));
    _toast('Fingerprint / face unlock is on.');
  }

  String _bioStatusMessage(String status) => switch (status) {
    'unsupportedApi' =>
      'Fingerprint unlock needs Android 9 or newer on this phone; '
          'your PIN still protects the app.',
    'noneEnrolled' =>
      'No fingerprint or face is enrolled on this phone yet — add '
          'one in Android Settings first.',
    'noDeviceLock' =>
      'Set a device lock screen (PIN/pattern) in Android Settings '
          'first.',
    _ => 'Biometrics are not available on this phone.',
  };

  /// v1.1 (spec §4.5): the overall monthly budget, stored in
  /// paise. Empty input clears it (overall alerts off, decision #3).
  Future<void> _editOverallCap() async {
    final ctl = TextEditingController(
      text: _s.overallMonthlyCapPaise == null
          ? ''
          : rupeesFromPaise(_s.overallMonthlyCapPaise!).toStringAsFixed(0),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Overall monthly budget'),
        content: TextField(
          controller: ctl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: const InputDecoration(
            prefixText: '₹ ',
            labelText: 'Total spend cap per month (blank = off)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final text = ctl.text.replaceAll(',', '').trim();
    ctl.dispose();
    if (saved != true) return;
    if (text.isEmpty) {
      await _update(_s.copyWith(clearOverallMonthlyCap: true));
      return;
    }
    final rupees = double.tryParse(text);
    if (rupees == null || rupees <= 0) {
      _toast('Enter an amount above zero, or leave it blank for off.');
      return;
    }
    await _update(
      _s.copyWith(overallMonthlyCapPaise: paiseFromRupees(rupees)),
    );
  }

  Future<void> _testSummary() async {
    await widget.capture.requestNotificationPermission();
    final ok = await widget.capture.postSummaryNow(widget.summaryLine);
    _toast(
      ok
          ? 'Summary notification sent: ${widget.summaryLine}'
          : 'Notification could not be posted — check notification permission.',
    );
  }

  Future<void> _contact() async {
    final ok = await widget.capture.openMail('gunahacker7@gmail.com');
    if (!ok) {
      _toast('No mail app found — write to gunahacker7@gmail.com');
    }
  }

  Future<void> _dangerWipe() async {
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete ALL Kanakku data?'),
        content: const Text(
          'Every transaction, budget, split, imported statement, '
          'setting and the app PIN will be permanently deleted from '
          'this phone. There is no undo — a backup file you saved '
          'elsewhere is the only way back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep my data'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: KanakkuTheme.debit),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (first != true || !mounted) return;
    final second = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Are you absolutely sure?'),
        content: const Text(
          'This is the final confirmation. Kanakku will restart '
          'with empty, first-run data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: KanakkuTheme.debit),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, delete it all'),
          ),
        ],
      ),
    );
    if (second != true || !mounted) return;
    await widget.onWipeData();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ---- row builders ------------------------------------------------

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 8),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w700,
        color: KanakkuTheme.inkSoft,
      ),
    ),
  );

  Widget _row({
    required IconData icon,
    required String title,
    String? value,
    VoidCallback? onTap,
    Widget? trailing,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      leading: Icon(icon, color: KanakkuTheme.teal),
      title: Text(title),
      subtitle: value == null
          ? null
          : Text(value, style: TextStyle(color: KanakkuTheme.inkSoft)),
      trailing:
          trailing ??
          (onTap != null
              ? Icon(Icons.chevron_right, color: KanakkuTheme.inkSoft)
              : null),
      onTap: onTap,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final staleBackup =
        _s.lastBackupAt == null ||
        DateTime.now()
                .difference(
                  DateTime.fromMillisecondsSinceEpoch(_s.lastBackupAt!),
                )
                .inDays >=
            7;
    final reminderLabel = KanakkuTheme.fmtTimeOfDay(
      _s.dailyReminderHour,
      _s.dailyReminderMinute,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // ---- 0. Profile -----------------------------------------
          // v1.0.1: profile CARD in the reference style — teal
          // avatar (initial, or a person icon before a name is
          // set), bold serif username with the pencil on the card,
          // "Local account" subtitle (Kanakku has no sign-in and
          // does not fake one), backup nudge under a hairline.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: KanakkuTheme.teal,
                        child: _s.profileName.isEmpty
                            ? const Icon(
                                Icons.person,
                                color: Colors.white,
                                size: 28,
                              )
                            : Text(
                                _s.profileName[0].toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _s.profileName.isEmpty
                                  ? 'Guest'
                                  : _s.profileName,
                              style: KanakkuTheme.serif(size: 21),
                            ),
                            Text(
                              'Local account',
                              style: TextStyle(
                                color: KanakkuTheme.inkSoft,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit name',
                        onPressed: _editName,
                      ),
                    ],
                  ),
                  if (staleBackup) ...[
                    const SizedBox(height: 12),
                    Divider(color: KanakkuTheme.dividerColor, height: 1),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          Icons.backup_outlined,
                          size: 18,
                          color: KanakkuTheme.wants,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            "Your data hasn't been backed up in a while.",
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        TextButton(
                          onPressed: () => widget.onBackup(),
                          child: const Text('Backup now'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      ActionChip(
                        label: const Text('Transactions'),
                        onPressed: () => widget.onJumpTab(1),
                      ),
                      ActionChip(
                        label: const Text('Budgets'),
                        onPressed: () => widget.onJumpTab(2),
                      ),
                      ActionChip(
                        label: const Text('Categories'),
                        onPressed: widget.onOpenCategories,
                      ),
                      ActionChip(
                        label: const Text('Insights'),
                        onPressed: () => widget.onJumpTab(3),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ---- 1. Preferences --------------------------------------
          _section('Preferences'),
          _row(
            icon: Icons.currency_rupee,
            title: 'Currency & Format',
            value: 'INR (₹)',
            onTap: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: KanakkuTheme.card,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (ctx) => const SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 24),
                  child: Text(
                    'Kanakku works in Indian Rupees (₹) only for now. '
                    'Multi-currency support is not built yet, so amounts '
                    'are never converted or re-labelled behind your back.',
                    style: TextStyle(fontSize: 14, height: 1.45),
                  ),
                ),
              ),
            ),
          ),
          _row(
            icon: Icons.payments_outlined,
            title: 'Default Payment Mode',
            value: _s.defaultPaymentMode,
            onTap: () async {
              final v = await _pickChoice(
                'Default Payment Mode',
                paymentModes,
                _s.defaultPaymentMode,
              );
              if (v != null) await _update(_s.copyWith(defaultPaymentMode: v));
            },
          ),
          _row(
            icon: Icons.category_outlined,
            title: 'Default Expense Category',
            value: _s.defaultExpenseCategory,
            onTap: () async {
              final v = await _pickChoice(
                'Default Expense Category',
                expenseCategoryOptions,
                _s.defaultExpenseCategory,
              );
              if (v != null) {
                await _update(_s.copyWith(defaultExpenseCategory: v));
              }
            },
          ),
          _row(
            icon: Icons.savings_outlined,
            title: 'Default Income Category',
            value: _s.defaultIncomeCategory,
            onTap: () async {
              final v = await _pickChoice(
                'Default Income Category',
                incomeTypes,
                _s.defaultIncomeCategory,
              );
              if (v != null) {
                await _update(_s.copyWith(defaultIncomeCategory: v));
              }
            },
          ),
          _row(
            icon: Icons.calendar_month_outlined,
            title: 'First Day of the Month',
            value: _s.monthStartDay == 1
                ? '1st (calendar month)'
                : 'Day ${_s.monthStartDay}',
            onTap: () async {
              final v = await _pickChoice('First Day of the Month', [
                for (var d = 1; d <= 28; d++) '$d',
              ], '${_s.monthStartDay}');
              if (v != null) {
                await _update(_s.copyWith(monthStartDay: int.parse(v)));
              }
            },
          ),
          _row(
            icon: Icons.view_week_outlined,
            title: 'Week Starts On',
            value: _s.weekStartsOn,
            onTap: () async {
              final v = await _pickChoice('Week Starts On', const [
                'Monday',
                'Sunday',
              ], _s.weekStartsOn);
              if (v != null) await _update(_s.copyWith(weekStartsOn: v));
            },
          ),
          _row(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Home Page Balance View',
            value: _s.homeBalanceView == 'accounts'
                ? 'Account balances total'
                : 'Net balance',
            onTap: () async {
              final v = await _pickChoice(
                'Home Page Balance View',
                const ['Net balance', 'Account balances total'],
                _s.homeBalanceView == 'accounts'
                    ? 'Account balances total'
                    : 'Net balance',
              );
              if (v != null) {
                await _update(
                  _s.copyWith(
                    homeBalanceView: v == 'Account balances total'
                        ? 'accounts'
                        : 'net',
                  ),
                );
              }
            },
          ),
          _row(
            icon: Icons.vibration_outlined,
            title: 'Haptics',
            value: _s.haptics ? 'On' : 'Off',
            trailing: Switch(
              value: _s.haptics,
              activeThumbColor: KanakkuTheme.teal,
              onChanged: (v) => _update(_s.copyWith(haptics: v)),
            ),
          ),

          // ---- 2. Appearance ---------------------------------------
          _section('Appearance'),
          _row(
            icon: Icons.dark_mode_outlined,
            title: 'Theme',
            value: switch (_s.themeMode) {
              'dark' => 'Dark',
              'light' => 'Light',
              _ => 'Device theme',
            },
            onTap: () async {
              final v = await _pickChoice(
                'Theme',
                const ['Light', 'Dark', 'Device theme'],
                switch (_s.themeMode) {
                  'dark' => 'Dark',
                  'light' => 'Light',
                  _ => 'Device theme',
                },
              );
              if (v != null) {
                await _update(
                  _s.copyWith(
                    themeMode: v == 'Dark'
                        ? 'dark'
                        : v == 'Light'
                        ? 'light'
                        : 'device',
                  ),
                );
              }
            },
          ),
          _row(
            icon: Icons.schedule_outlined,
            title: 'Time Format',
            value: _s.timeFormat == '24h' ? '24-Hour' : '12-Hour',
            onTap: () async {
              final v = await _pickChoice('Time Format', const [
                '12-Hour',
                '24-Hour',
              ], _s.timeFormat == '24h' ? '24-Hour' : '12-Hour');
              if (v != null) {
                await _update(
                  _s.copyWith(timeFormat: v == '24-Hour' ? '24h' : '12h'),
                );
              }
            },
          ),
          _row(
            icon: Icons.numbers_outlined,
            title: 'Decimal Format',
            value: _s.decimalFormat == 'none'
                ? 'No decimals (₹1,235)'
                : 'Full (₹1,234.56)',
            onTap: () async {
              final v = await _pickChoice(
                'Decimal Format',
                const ['Full (₹1,234.56)', 'No decimals (₹1,235)'],
                _s.decimalFormat == 'none'
                    ? 'No decimals (₹1,235)'
                    : 'Full (₹1,234.56)',
              );
              if (v != null) {
                await _update(
                  _s.copyWith(
                    decimalFormat: v.startsWith('No') ? 'none' : 'full',
                  ),
                );
              }
            },
          ),

          // ---- 3. Notifications -------------------------------------
          _section('Notifications'),
          _row(
            icon: Icons.notifications_outlined,
            title: 'Daily Reminder',
            value: _s.dailyReminderOn
                ? 'Every day at $reminderLabel · ${widget.summaryLine}'
                : 'Off',
            trailing: Switch(
              value: _s.dailyReminderOn,
              activeThumbColor: KanakkuTheme.teal,
              onChanged: (v) => _update(_s.copyWith(dailyReminderOn: v)),
            ),
          ),
          if (_s.dailyReminderOn) ...[
            _row(
              icon: Icons.alarm_outlined,
              title: 'Reminder time',
              value: reminderLabel,
              onTap: _pickReminderTime,
            ),
            _row(
              icon: Icons.send_outlined,
              title: 'Send a test summary now',
              value: widget.summaryLine,
              onTap: _testSummary,
            ),
          ],

          // ---- 4. Backup, Restore & Export ---------------------------
          _section('Backup, Restore & Export'),
          _row(
            icon: Icons.backup_outlined,
            title: 'Backup Data',
            value: _s.lastBackupAt == null
                ? 'Never backed up'
                : 'Last backup ${_fmtDay(DateTime.fromMillisecondsSinceEpoch(_s.lastBackupAt!))}',
            onTap: () => widget.onBackup(),
          ),
          _row(
            icon: Icons.restore_outlined,
            title: 'Restore Data',
            value: 'From a Kanakku backup (.json) — replaces current data',
            onTap: () => widget.onRestore(),
          ),
          _row(
            icon: Icons.ios_share_outlined,
            title: 'Export Transactions',
            value: 'CSV or PDF',
            onTap: widget.onExport,
          ),
          _row(
            icon: Icons.upload_file_outlined,
            title: 'Import Transactions',
            value: 'Bank statement CSV upload & analysis',
            onTap: widget.onImportStatement,
          ),

          // ---- 5. Security -------------------------------------------
          _section('Security'),
          _row(
            icon: Icons.lock_outline,
            title: _pinSet == null
                ? 'App Lock (PIN) — checking…'
                : _pinSet!
                ? 'App Lock (PIN) is ON'
                : 'App Lock (PIN) is OFF',
            value:
                'A privacy screen: asked at launch and after a minute '
                'in the background, with a growing wait after wrong '
                'PINs. It does not encrypt your data.',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: _pinSet == null ? null : _setOrChange,
                  child: Text(_pinSet == true ? 'Change' : 'Set PIN'),
                ),
                if (_pinSet == true)
                  TextButton(onPressed: _disable, child: const Text('Disable')),
              ],
            ),
          ),
          _row(
            icon: Icons.visibility_off_outlined,
            title: 'Balance privacy',
            value: _s.balancePrivacy
                ? 'Balances hidden until you tap to reveal'
                : 'Balances always visible',
            trailing: Switch(
              value: _s.balancePrivacy,
              activeThumbColor: KanakkuTheme.teal,
              onChanged: (v) => _update(_s.copyWith(balancePrivacy: v)),
            ),
          ),
          // v1.1 (spec §5.3): biometric unlock toggle — enabling
          // runs the PIN-verify → probe → prompt gauntlet in
          // _toggleBiometric; nothing persists before it passes.
          _row(
            icon: Icons.fingerprint,
            title: 'Fingerprint / face unlock',
            value: _pinSet != true
                ? 'Set an app PIN first — biometrics unlock the PIN gate.'
                : _bioStatus == 'unsupportedApi'
                ? 'Fingerprint unlock needs Android 9 or newer on this '
                      'phone; your PIN still protects the app.'
                : 'Unlock with the fingerprint or face enrolled on '
                      'this phone, instead of typing the PIN.',
            trailing: Switch(
              value: _s.biometricUnlock,
              activeThumbColor: KanakkuTheme.teal,
              onChanged: _pinSet == true ? _toggleBiometric : null,
            ),
          ),
          // v1.1 (spec §5.5): the corrected security position,
          // verbatim — the lock is a privacy screen, and device
          // biometrics are enrollment-blind (decision #6).
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              'App lock keeps casual viewers out. Anyone who can '
              'unlock this phone — including a fingerprint added '
              'later — can open Kanakku.',
              style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
            ),
          ),

          // ---- 5b. Budgets & alerts (v1.1) -------------------------
          _section('Budgets & Alerts'),
          _row(
            icon: Icons.notifications_outlined,
            title: 'Budget alerts',
            value: budgetAlertHonestyLine,
            trailing: Switch(
              value: _s.budgetAlertsOn,
              activeThumbColor: KanakkuTheme.teal,
              onChanged: (v) => _update(_s.copyWith(budgetAlertsOn: v)),
            ),
          ),
          _row(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Overall monthly budget',
            value: _s.overallMonthlyCapPaise == null
                ? 'Not set — overall alerts are off'
                : '${KanakkuTheme.inr(rupeesFromPaise(_s.overallMonthlyCapPaise!))} per month across all spending',
            onTap: _editOverallCap,
          ),

          // ---- 6. Categories ------------------------------------------
          _section('Categories'),
          _row(
            icon: Icons.label_outlined,
            title: 'Categories & merchant rules',
            value: 'Custom categories and keyword rules win over defaults',
            onTap: widget.onOpenCategories,
          ),

          // ---- 8. Support & Feedback ----------------------------------
          _section('Support & Feedback'),
          _row(
            icon: Icons.help_outline,
            title: 'FAQs',
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const _FaqPage())),
          ),
          _row(
            icon: Icons.feedback_outlined,
            title: 'Query and Feedback',
            value: 'Opens your mail app',
            onTap: _contact,
          ),
          _row(
            icon: Icons.mail_outline,
            title: 'Contact Us',
            value: 'gunahacker7@gmail.com',
            onTap: _contact,
          ),

          // ---- 9. More --------------------------------------------------
          _section('More'),
          _row(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _TextPage(
                  title: 'Privacy Policy',
                  body: _privacyText,
                ),
              ),
            ),
          ),
          _row(
            icon: Icons.description_outlined,
            title: 'Terms of Service',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _TextPage(
                  title: 'Terms of Service',
                  body: _termsText,
                ),
              ),
            ),
          ),
          _row(
            icon: Icons.info_outline,
            title: 'About App',
            value: 'Kanakku v$kanakkuVersion · Every rupee, accounted.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    const _TextPage(title: 'About Kanakku', body: _aboutText),
              ),
            ),
          ),

          // ---- 10. Danger Zone ------------------------------------------
          _section('Danger Zone'),
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const Icon(
                Icons.delete_forever_outlined,
                color: KanakkuTheme.debit,
              ),
              title: const Text(
                'Delete Data & Start Afresh',
                style: TextStyle(
                  color: KanakkuTheme.debit,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(
                'Permanently deletes everything on this phone. No undo.',
                style: TextStyle(color: KanakkuTheme.inkSoft),
              ),
              onTap: _dangerWipe,
            ),
          ),
        ],
      ),
    );
  }
}

/// App version shown in About (kept in step with pubspec.yaml).
const kanakkuVersion = '1.1.5';

const _privacyText = '''
Kanakku keeps your money data on this phone. Nothing is uploaded to a server — there is no Kanakku account and no cloud copy.

• SMS access is used only to read bank and UPI transaction messages and turn them into entries. OTPs and promotional messages are ignored by the parser.
• Notification access, if you grant it, reads payment-app alerts for the same purpose.
• Imported bank statements are parsed on the phone and stored on the phone.
• Backups are files you create and share yourself; Kanakku never sends them anywhere.
• The app PIN is stored only as a salted hash. It never leaves the phone and is never included in a backup.

If you delete the app or use "Delete Data & Start Afresh", everything is gone from the device.''';

const _termsText = '''
Kanakku is a personal finance tracker provided as-is, without warranty of any kind.

• Figures come from your messages, statements and manual entries. Parsing can miss or misread a transaction — verify important numbers against your bank before acting on them.
• Kanakku does not provide financial, tax or investment advice, and does not move money.
• You are responsible for keeping your phone, PIN and backup files safe.
• By using the app you accept these terms.''';

const _aboutText =
    '''
Kanakku (கணக்கு) — personal finance, in Tamil first.

Version $kanakkuVersion

Every rupee, accounted.

Kanakku captures expenses automatically from bank SMS and payment notifications, keeps budgets for your month, reminds you about card bills, and exports clean CSV/PDF statements — all on your own phone.''';

/// Static FAQ page (Support & Feedback).
class _FaqPage extends StatelessWidget {
  const _FaqPage();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('FAQs')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        for (final (q, a) in _faqs)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              title: Text(
                q,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(a, style: const TextStyle(height: 1.45)),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

const _faqs = <(String, String)>[
  (
    'How does Kanakku capture my expenses?',
    'With your permission, Kanakku reads bank and UPI transaction SMS and payment-app notifications, and parses amounts, accounts and balances on the phone. Nothing is uploaded anywhere.',
  ),
  (
    'Why is an expense missing?',
    'Check that SMS permission and notification access are granted, then pull to refresh on Home. Some banks send formats the parser has not seen yet — add those manually, and the entry still counts in budgets and insights.',
  ),
  (
    'Is my data uploaded or shared?',
    'No. There is no Kanakku server and no account. Data leaves the phone only when you export a CSV/PDF or share a backup file yourself.',
  ),
  (
    'What happens if I forget my PIN?',
    'After 5 wrong tries, PIN entry pauses — 30 seconds at first, doubling each time (up to 15 minutes). There is no reset shortcut on the lock screen: the PIN can only be changed or switched off in Settings after unlocking. If the PIN is truly lost, the only way back is clearing the app data in Android settings (or reinstalling), which erases Kanakku\u2019s on-device data — restoring a backup file afterwards brings your records back.',
  ),
  (
    'How do backups work?',
    'Settings → Backup Data creates one JSON file with every store (the PIN is never included). Choose "Encrypt" to lock it with a passphrase — recommended, since a plain backup is readable by anyone who gets the file. Restore Data reads it back (asking for the passphrase if encrypted) and replaces the current data after a confirmation.',
  ),
  (
    'Can Kanakku read my PDF bank statement?',
    'Not yet — download the CSV or Excel statement from your bank app and upload that instead. PDF parsing is planned.',
  ),
];

/// Simple static text page (Privacy / Terms / About).
class _TextPage extends StatelessWidget {
  final String title;
  final String body;
  const _TextPage({required this.title, required this.body});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Text(body.trim(), style: const TextStyle(height: 1.55)),
    ),
  );
}

/// Categories page (v1.0): every category with its bucket, plus
/// user-added categories and keyword → category merchant rules.
/// Personal rules are checked before the built-in table, so a rule
/// like "landlord → Rent" always wins.
// =====================================================================
// v1.1 Recurring (spec §3.1): rules list, restored-rule review,
// flagged-occurrence resolution, possible refunds, rule detail and
// the create/edit form.
// =====================================================================

class _RecurringPage extends StatefulWidget {
  final Map<String, dynamic> doc;
  final List<Map<String, dynamic>> manualMaps;
  final List<ParsedTransaction> captures;
  final List<CategoryDef> categoryDefs;
  final List<String> notices;
  final Future<void> Function(
    Map<String, dynamic>,
    List<Map<String, dynamic>>,
  )
  onApply;
  const _RecurringPage({
    required this.doc,
    required this.manualMaps,
    required this.captures,
    required this.categoryDefs,
    required this.notices,
    required this.onApply,
  });
  @override
  State<_RecurringPage> createState() => _RecurringPageState();
}

class _RecurringPageState extends State<_RecurringPage> {
  late final Map<String, dynamic> _doc = widget.doc;
  late final List<Map<String, dynamic>> _maps = widget.manualMaps;

  Future<void> _apply() async {
    await widget.onApply(_doc, _maps);
    if (mounted) setState(() {});
  }

  ParsedTransaction? _captureByKey(String key) {
    for (final t in widget.captures) {
      if (entryId(t) == key) return t;
    }
    return null;
  }

  Future<void> _openForm([Map<String, dynamic>? existing]) async {
    final draft = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => _RuleFormPage(
          categoryDefs: widget.categoryDefs,
          initial: existing,
        ),
      ),
    );
    if (draft == null || !mounted) return;
    final rules = rulesOf(_doc);
    final id = draft['id']?.toString();
    if (id != null && id.isNotEmpty && ruleById(_doc, id) != null) {
      final i = rules.indexWhere((r) => r['id'] == id);
      rules[i] = normalizeRule(draft);
    } else {
      draft['id'] = newRuleId(
        _doc,
        DateTime.now().millisecondsSinceEpoch,
      );
      draft['createdAt'] = DateTime.now().millisecondsSinceEpoch;
      rules.add(normalizeRule(draft));
    }
    await _apply();
  }

  Widget _flagCard(Map<String, dynamic> rule, Map<String, dynamic> occ) {
    final reason = occ['flagReason']?.toString();
    final amount = KanakkuTheme.inr(
      rupeesFromPaise((occ['amountPaise'] as num).toInt()),
    );
    final when = parseDateStr(occ['date'] as String);
    final title = '${rule['label']} · $amount · '
        '${when != null ? _fmtDay(when) : occ['date']}';
    final buttons = <Widget>[];
    if (reason == 'ambiguousMatch') {
      final cands = occ['flagCandidates'];
      if (cands is List) {
        for (final k in cands) {
          final cap = _captureByKey(k.toString());
          buttons.add(
            OutlinedButton(
              onPressed: () async {
                resolveFlaggedMatch(
                  _doc,
                  rule['id'] as String,
                  occ['date'] as String,
                  k.toString(),
                );
                await _apply();
              },
              child: Text(
                'This is the payment: '
                '${cap != null ? '${_fmtDay(cap.receivedAt)} · ${cap.counterparty ?? cap.bankHint ?? 'Bank'}' : k}',
              ),
            ),
          );
        }
      }
      buttons.add(
        FilledButton(
          onPressed: () async {
            postFlaggedOccurrence(
              _doc,
              _maps,
              rule['id'] as String,
              occ['date'] as String,
              DateTime.now(),
            );
            await _apply();
          },
          child: const Text('Post entry instead'),
        ),
      );
      buttons.add(
        TextButton(
          onPressed: () async {
            skipFlaggedOccurrence(
              _doc,
              rule['id'] as String,
              occ['date'] as String,
            );
            await _apply();
          },
          child: const Text('Skip'),
        ),
      );
    } else if (reason == 'possibleDuplicate') {
      buttons.addAll([
        FilledButton(
          onPressed: () async {
            resolveFlaggedDuplicate(
              _doc,
              _maps,
              rule['id'] as String,
              occ['date'] as String,
              removeGenerated: false,
            );
            await _apply();
          },
          child: const Text('Keep both'),
        ),
        OutlinedButton(
          onPressed: () async {
            resolveFlaggedDuplicate(
              _doc,
              _maps,
              rule['id'] as String,
              occ['date'] as String,
              removeGenerated: true,
            );
            await _apply();
          },
          child: const Text('Remove generated'),
        ),
      ]);
    } else {
      // creditUnseen (§3.6): confirm-before-posting.
      buttons.addAll([
        FilledButton(
          onPressed: () async {
            postFlaggedOccurrence(
              _doc,
              _maps,
              rule['id'] as String,
              occ['date'] as String,
              DateTime.now(),
            );
            await _apply();
          },
          child: const Text('Post it'),
        ),
        TextButton(
          onPressed: () async {
            skipFlaggedOccurrence(
              _doc,
              rule['id'] as String,
              occ['date'] as String,
            );
            await _apply();
          },
          child: const Text('Skip'),
        ),
      ]);
    }
    return Card(
      color: const Color(0xFFFDEFD2),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              reason == 'creditUnseen'
                  ? 'Expected income not seen — post it manually?'
                  : reason == 'possibleDuplicate'
                  ? 'Possible duplicate — a real payment may already cover this entry.'
                  : 'More than one payment could be this one — pick the right one, or post the entry.',
              style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: buttons),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rules = rulesOf(_doc);
    final today = dateStr(DateTime.now());
    final held = rules
        .where(
          (r) => r['restoredHold'] == true && r['holdReviewed'] != true,
        )
        .toList();
    final flagged = <(Map<String, dynamic>, Map<String, dynamic>)>[
      for (final r in rules)
        for (final o in occurrencesOf(r))
          if (o['state'] == 'flagged') (r, o),
    ];
    final refunds = possibleRefunds(_doc, widget.captures);
    return Scaffold(
      appBar: AppBar(title: const Text('Recurring')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        backgroundColor: KanakkuTheme.teal,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(
            'Expected payments, checked when you open Kanakku. Each '
            'one is matched against your real SMS/notification '
            'payments first — only when no payment shows up does '
            'Kanakku post the entry itself.',
            style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
          ),
          for (final n in widget.notices) ...[
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(n, style: const TextStyle(fontSize: 13)),
              ),
            ),
          ],
          for (final r in held) ...[
            const SizedBox(height: 10),
            Card(
              color: const Color(0xFFFDEFD2),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Restored rule — ${r['label']}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'This rule came back with a backup. It stays '
                      'paused until you resume it.',
                      style: TextStyle(
                        color: KanakkuTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: () async {
                            resumeRule(r, today);
                            r.remove('holdReviewed');
                            await _apply();
                          },
                          child: const Text('Resume'),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            r['status'] = 'paused';
                            r['holdReviewed'] = true;
                            await _apply();
                          },
                          child: const Text('Keep paused'),
                        ),
                        TextButton(
                          onPressed: () async {
                            rulesOf(_doc).remove(r);
                            await _apply();
                          },
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (flagged.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Needs your decision', style: KanakkuTheme.serif(size: 17)),
            const SizedBox(height: 8),
            for (final (r, o) in flagged) _flagCard(r, o),
          ],
          if (refunds.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Possible refunds?', style: KanakkuTheme.serif(size: 17)),
            const SizedBox(height: 4),
            Text(
              'Captured money-in that mentions a rule but matched '
              'nothing. Shown for information only — never linked '
              'automatically.',
              style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
            ),
            const SizedBox(height: 8),
            for (final c in refunds)
              Card(
                child: ListTile(
                  title: Text(c.txn.counterparty ?? 'Money in'),
                  subtitle: Text(_fmtDay(c.txn.receivedAt)),
                  trailing: Text(
                    '+${KanakkuTheme.inr(c.txn.amount)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: KanakkuTheme.credit,
                    ),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Text('Your rules', style: KanakkuTheme.serif(size: 17)),
          const SizedBox(height: 8),
          if (rules.isEmpty)
            Text(
              'No recurring rules yet. Tap + to add one, or '
              'long-press any transaction and choose "Repeat this".',
              style: TextStyle(color: KanakkuTheme.inkSoft),
            )
          else
            for (final r in rules)
              Card(
                child: ListTile(
                  title: Text(
                    r['label'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${humanSchedule(r)} · '
                    '${r['restoredHold'] == true ? 'Restored — paused' : (r['status'] as String)[0].toUpperCase() + (r['status'] as String).substring(1)}'
                    '${nextDueDate(r, today) != null ? ' · Next ${nextDueDate(r, today)}' : ''}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${r['dir'] == 'credit' ? '+' : '−'}${KanakkuTheme.inr(rupeesFromPaise((r['amountPaise'] as num).toInt()))}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      IconButton(
                        icon: Icon(
                          r['status'] == 'paused'
                              ? Icons.play_arrow_outlined
                              : Icons.pause_outlined,
                          size: 20,
                        ),
                        tooltip: r['status'] == 'paused'
                            ? 'Resume'
                            : 'Pause',
                        onPressed: r['status'] == 'ended'
                            ? null
                            : () async {
                                if (r['status'] == 'paused' ||
                                    r['restoredHold'] == true) {
                                  resumeRule(r, today);
                                  r.remove('holdReviewed');
                                } else {
                                  pauseRule(r, today);
                                }
                                await _apply();
                              },
                      ),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _RuleDetailPage(
                        rule: r,
                        doc: _doc,
                        manualMaps: _maps,
                        onApply: _apply,
                        onEdit: () => _openForm(r),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Rule detail: schedule summary, actions, occurrence history
/// (posted occurrences show their real posting date, spec §2.2).
class _RuleDetailPage extends StatelessWidget {
  final Map<String, dynamic> rule;
  final Map<String, dynamic> doc;
  final List<Map<String, dynamic>> manualMaps;
  final Future<void> Function() onApply;
  final VoidCallback onEdit;
  const _RuleDetailPage({
    required this.rule,
    required this.doc,
    required this.manualMaps,
    required this.onApply,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final today = dateStr(DateTime.now());
    final occs = [...occurrencesOf(rule)]
      ..sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
    String postedLine(Map<String, dynamic> o) {
      final id = o['entryId']?.toString();
      if (id == null) return '';
      for (final m in manualMaps) {
        if (entryId(manualTxnFromJson(m)) == id) {
          final p = (m['postedAt'] as num?)?.toInt();
          if (p != null) {
            return ' · Posted ${_fmtDay(DateTime.fromMillisecondsSinceEpoch(p))}';
          }
        }
      }
      return '';
    }

    return Scaffold(
      appBar: AppBar(title: Text(rule['label'] as String)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${rule['dir'] == 'credit' ? '+' : '−'}${KanakkuTheme.inr(rupeesFromPaise((rule['amountPaise'] as num).toInt()))} · ${humanSchedule(rule)}',
                    style: KanakkuTheme.serif(size: 18),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Category ${rule['category']} · ${rule['mode']}'
                    '${rule['accountLast4'] != null ? ' · Account …${rule['accountLast4']}' : ''}'
                    '\nStatus: ${rule['restoredHold'] == true ? 'Restored — paused' : rule['status']}'
                    ' · Fired ${rule['firedCount']} time${rule['firedCount'] == 1 ? '' : 's'}'
                    '${nextDueDate(rule, today) != null ? ' · Next due ${nextDueDate(rule, today)}' : ''}',
                    style: TextStyle(
                      color: KanakkuTheme.inkSoft,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('Edit'),
                      ),
                      if (rule['status'] == 'active' &&
                          rule['restoredHold'] != true)
                        OutlinedButton.icon(
                          onPressed: () async {
                            pauseRule(rule, today);
                            await onApply();
                            if (context.mounted) Navigator.pop(context);
                          },
                          icon: const Icon(Icons.pause_outlined, size: 16),
                          label: const Text('Pause'),
                        ),
                      if (rule['status'] == 'paused' ||
                          rule['restoredHold'] == true)
                        OutlinedButton.icon(
                          onPressed: () async {
                            resumeRule(rule, today);
                            rule.remove('holdReviewed');
                            await onApply();
                            if (context.mounted) Navigator.pop(context);
                          },
                          icon: const Icon(
                            Icons.play_arrow_outlined,
                            size: 16,
                          ),
                          label: const Text('Resume'),
                        ),
                      if (rule['status'] != 'ended')
                        OutlinedButton.icon(
                          onPressed: () async {
                            rule['status'] = 'ended';
                            await onApply();
                            if (context.mounted) Navigator.pop(context);
                          },
                          icon: const Icon(Icons.stop_outlined, size: 16),
                          label: const Text('End rule'),
                        ),
                      TextButton.icon(
                        onPressed: () async {
                          final go = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete this rule?'),
                              content: const Text(
                                'Posted entries stay in your '
                                'transactions. Unposted occurrences '
                                'are discarded.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(ctx, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(ctx, true),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (go != true) return;
                          rulesOf(doc).remove(rule);
                          await onApply();
                          if (context.mounted) Navigator.pop(context);
                        },
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: KanakkuTheme.debit,
                        ),
                        label: const Text(
                          'Delete',
                          style: TextStyle(color: KanakkuTheme.debit),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('History', style: KanakkuTheme.serif(size: 17)),
          const SizedBox(height: 8),
          if (occs.isEmpty)
            Text(
              'Nothing yet — the first occurrence is created on its due date.',
              style: TextStyle(color: KanakkuTheme.inkSoft),
            )
          else
            for (final o in occs)
              Card(
                child: ListTile(
                  title: Text(
                    '${o['date']} · ${o['state']}'
                    '${o['state'] == 'posted' ? postedLine(o) : ''}',
                  ),
                  trailing: Text(
                    KanakkuTheme.inr(
                      rupeesFromPaise((o['amountPaise'] as num).toInt()),
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Create/edit form for a recurring rule (spec §3.1). Returns the
/// rule map (with 'id' when editing an existing rule; without one
/// for a new rule — the caller allocates the id).
class _RuleFormPage extends StatefulWidget {
  final List<CategoryDef> categoryDefs;
  final Map<String, dynamic>? initial;
  const _RuleFormPage({required this.categoryDefs, this.initial});
  @override
  State<_RuleFormPage> createState() => _RuleFormPageState();
}

class _RuleFormPageState extends State<_RuleFormPage> {
  late final TextEditingController _label = TextEditingController(
    text: widget.initial?['label']?.toString() ?? '',
  );
  late final TextEditingController _matchText = TextEditingController(
    text:
        widget.initial?['matchText']?.toString() ??
        widget.initial?['label']?.toString() ??
        '',
  );
  late final TextEditingController _amount = TextEditingController(
    text: widget.initial?['amountPaise'] != null
        ? rupeesFromPaise(
            (widget.initial!['amountPaise'] as num).toInt(),
          ).toStringAsFixed(2)
        : '',
  );
  late final TextEditingController _last4 = TextEditingController(
    text: widget.initial?['accountLast4']?.toString() ?? '',
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.initial?['note']?.toString() ?? '',
  );
  late final TextEditingController _every = TextEditingController(
    text:
        ((widget.initial?['interval'] as Map?)?['every'] ?? 1).toString(),
  );
  late final TextEditingController _dayOfMonth = TextEditingController(
    text:
        ((widget.initial?['interval'] as Map?)?['dayOfMonth'] ?? 1)
            .toString(),
  );
  late final TextEditingController _maxCount = TextEditingController(
    text: widget.initial?['maxCount']?.toString() ?? '',
  );
  late String _dir = widget.initial?['dir']?.toString() ?? 'debit';
  late String _category =
      widget.initial?['category']?.toString() ??
      widget.categoryDefs.first.name;
  late String _bucket = widget.initial?['bucket']?.toString() ?? 'needs';
  late String _mode = widget.initial?['mode']?.toString() ?? 'Cash';
  late String _policy =
      widget.initial?['capturePolicy']?.toString() ??
      (_mode == 'Cash' ? 'auto' : 'matchOrPost');
  late bool _policyTouched = widget.initial?['capturePolicy'] != null;
  late String _intervalType =
      ((widget.initial?['interval'] as Map?)?['type']?.toString()) ??
      'monthly';
  late int _weekday =
      ((widget.initial?['interval'] as Map?)?['weekday'] as num?)
          ?.toInt() ??
      DateTime.now().weekday;
  late DateTime _startDate =
      parseDateStr(widget.initial?['startDate']?.toString() ?? '') ??
      DateTime.now();
  late String _endKind = widget.initial?['endDate'] != null
      ? 'date'
      : widget.initial?['maxCount'] != null
      ? 'count'
      : 'none';
  late DateTime _endDate =
      parseDateStr(widget.initial?['endDate']?.toString() ?? '') ??
      DateTime.now().add(const Duration(days: 90));
  late int _grace =
      (widget.initial?['graceDays'] as num?)?.toInt() ?? 3;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _label,
      _matchText,
      _amount,
      _last4,
      _note,
      _every,
      _dayOfMonth,
      _maxCount,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<DateTime?> _pickDate(DateTime initial) => showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2020),
    lastDate: DateTime(2035),
  );

  void _save() {
    final label = _label.text.trim();
    final amount = double.tryParse(_amount.text.replaceAll(',', ''));
    var policy = _policy;
    if (_dir == 'credit') policy = 'matchOrPost'; // §3.6 guard
    if (label.isEmpty) {
      setState(() => _error = 'Give the rule a label.');
      return;
    }
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount above zero.');
      return;
    }
    final matchText = _matchText.text.trim().isEmpty
        ? label
        : _matchText.text.trim();
    if (policy == 'matchOrPost' && matchText.isEmpty) {
      setState(
        () => _error =
            'Match text cannot be empty for match-or-post rules.',
      );
      return;
    }
    final every = int.tryParse(_every.text) ?? 1;
    final dom = int.tryParse(_dayOfMonth.text) ?? _startDate.day;
    final base = widget.initial ?? <String, dynamic>{};
    final out = Map<String, dynamic>.from(base);
    out.addAll({
      'label': label,
      'matchText': matchText,
      'amountPaise': paiseFromRupees(amount),
      'dir': _dir,
      'category': _category,
      'bucket': _bucket,
      'mode': _mode,
      'interval': {
        'type': _intervalType,
        'every': every < 1 ? 1 : every,
        if (_intervalType == 'weekly') 'weekday': _weekday,
        if (_intervalType == 'monthly')
          'dayOfMonth': dom < 1 ? 1 : (dom > 31 ? 31 : dom),
      },
      'startDate': dateStr(_startDate),
      'capturePolicy': policy,
      'graceDays': _grace,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    final last4 = _last4.text.trim();
    if (last4.isEmpty) {
      out.remove('accountLast4');
    } else {
      out['accountLast4'] = last4;
    }
    if (_note.text.trim().isEmpty) {
      out.remove('note');
    } else {
      out['note'] = _note.text.trim();
    }
    out.remove('endDate');
    out.remove('maxCount');
    if (_endKind == 'date') out['endDate'] = dateStr(_endDate);
    if (_endKind == 'count') {
      final n = int.tryParse(_maxCount.text);
      if (n != null && n > 0) out['maxCount'] = n;
    }
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    final categories = <String>{
      for (final d in widget.categoryDefs) d.name,
      ...incomeTypes,
      _category,
    }.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initial?['id'] != null
              ? 'Edit rule'
              : 'New recurring rule',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'debit', label: Text('Expense')),
              ButtonSegment(value: 'credit', label: Text('Income')),
            ],
            selected: {_dir},
            onSelectionChanged: (s) => setState(() => _dir = s.first),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _label,
            decoration: const InputDecoration(labelText: 'Label'),
          ),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            decoration: const InputDecoration(
              prefixText: '₹ ',
              labelText: 'Amount',
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _category,
            items: [
              for (final c in categories)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                _category = v;
                for (final d in widget.categoryDefs) {
                  if (d.name == v) _bucket = d.bucket.name;
                }
              });
            },
            decoration: const InputDecoration(labelText: 'Category'),
          ),
          DropdownButtonFormField<String>(
            initialValue: _bucket,
            items: [
              for (final b in Bucket.values)
                DropdownMenuItem(value: b.name, child: Text(b.name)),
            ],
            onChanged: (v) => setState(() => _bucket = v ?? _bucket),
            decoration: const InputDecoration(labelText: 'Bucket'),
          ),
          DropdownButtonFormField<String>(
            initialValue: _mode,
            items: [
              for (final m in paymentModes)
                DropdownMenuItem(value: m, child: Text(m)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                _mode = v;
                // Mode drives the policy default (spec §3.1):
                // Cash defaults to auto-posting; anything else to
                // match-or-post — until the user picks explicitly.
                if (!_policyTouched) {
                  _policy = v == 'Cash' ? 'auto' : 'matchOrPost';
                }
              });
            },
            decoration: const InputDecoration(labelText: 'Payment mode'),
          ),
          TextField(
            controller: _last4,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: const InputDecoration(
              labelText: 'Account last 4 (optional)',
              counterText: '',
            ),
          ),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
            ),
          ),
          const SizedBox(height: 14),
          Text('Schedule', style: KanakkuTheme.serif(size: 16)),
          DropdownButtonFormField<String>(
            initialValue: _intervalType,
            items: const [
              DropdownMenuItem(value: 'daily', child: Text('Daily')),
              DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
              DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
              DropdownMenuItem(
                value: 'customDays',
                child: Text('Every N days'),
              ),
            ],
            onChanged: (v) =>
                setState(() => _intervalType = v ?? _intervalType),
            decoration: const InputDecoration(labelText: 'Repeats'),
          ),
          if (_intervalType != 'monthly')
            TextField(
              controller: _every,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Every'),
            ),
          if (_intervalType == 'weekly')
            DropdownButtonFormField<int>(
              initialValue: _weekday,
              items: const [
                DropdownMenuItem(value: 1, child: Text('Monday')),
                DropdownMenuItem(value: 2, child: Text('Tuesday')),
                DropdownMenuItem(value: 3, child: Text('Wednesday')),
                DropdownMenuItem(value: 4, child: Text('Thursday')),
                DropdownMenuItem(value: 5, child: Text('Friday')),
                DropdownMenuItem(value: 6, child: Text('Saturday')),
                DropdownMenuItem(value: 7, child: Text('Sunday')),
              ],
              onChanged: (v) => setState(() => _weekday = v ?? _weekday),
              decoration: const InputDecoration(labelText: 'Weekday'),
            ),
          if (_intervalType == 'monthly')
            TextField(
              controller: _dayOfMonth,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Day of month (1–31)',
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Start date'),
            trailing: Text(_fmtDay(_startDate)),
            onTap: () async {
              final d = await _pickDate(_startDate);
              if (d != null) setState(() => _startDate = d);
            },
          ),
          DropdownButtonFormField<String>(
            initialValue: _endKind,
            items: const [
              DropdownMenuItem(value: 'none', child: Text('No end')),
              DropdownMenuItem(value: 'date', child: Text('End date')),
              DropdownMenuItem(
                value: 'count',
                child: Text('After N times'),
              ),
            ],
            onChanged: (v) => setState(() => _endKind = v ?? _endKind),
            decoration: const InputDecoration(labelText: 'Ends'),
          ),
          if (_endKind == 'date')
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('End date'),
              trailing: Text(_fmtDay(_endDate)),
              onTap: () async {
                final d = await _pickDate(_endDate);
                if (d != null) setState(() => _endDate = d);
              },
            ),
          if (_endKind == 'count')
            TextField(
              controller: _maxCount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Times'),
            ),
          const SizedBox(height: 14),
          Text('When the payment is due', style: KanakkuTheme.serif(size: 16)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'matchOrPost',
                label: Text('Match, else post'),
              ),
              ButtonSegment(value: 'auto', label: Text('Always post')),
            ],
            selected: {_dir == 'credit' ? 'matchOrPost' : _policy},
            onSelectionChanged: _dir == 'credit'
                ? null
                : (s) => setState(() {
                    _policy = s.first;
                    _policyTouched = true;
                  }),
          ),
          if (_dir == 'credit')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Income rules always wait for a matching payment — '
                'if none arrives, Kanakku asks before posting.',
                style: TextStyle(
                  color: KanakkuTheme.inkSoft,
                  fontSize: 12,
                ),
              ),
            ),
          TextField(
            controller: _matchText,
            decoration: const InputDecoration(
              labelText: 'Match text (name in the bank message)',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Text('Grace days after the due date (0–14)'),
              ),
              IconButton(
                onPressed: _grace > 0
                    ? () => setState(() => _grace--)
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('$_grace', style: const TextStyle(fontSize: 16)),
              IconButton(
                onPressed: _grace < 14
                    ? () => setState(() => _grace++)
                    : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: KanakkuTheme.debit),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              backgroundColor: KanakkuTheme.teal,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Save rule'),
          ),
        ],
      ),
    );
  }
}

class _CategoriesPage extends StatefulWidget {
  final PersonalCategories personal;
  final Future<void> Function(PersonalCategories) onSave;

  /// v1.1 (spec §2.3): rename/delete must migrate the budget cap
  /// and current-month alert state in the same user action — the
  /// Shell owns those stores, so the page reports through these.
  final Future<void> Function(String oldName, String newName)?
  onRenameCategory;
  final Future<void> Function(String name)? onDeleteCategory;
  const _CategoriesPage({
    required this.personal,
    required this.onSave,
    this.onRenameCategory,
    this.onDeleteCategory,
  });
  @override
  State<_CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<_CategoriesPage> {
  late PersonalCategories _p = widget.personal;

  Future<void> _save(PersonalCategories next) async {
    setState(() => _p = next);
    await widget.onSave(next);
  }

  Future<void> _addCategory() async {
    final nameCtl = TextEditingController();
    var bucket = Bucket.needs;
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add category'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Category name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<Bucket>(
                initialValue: bucket,
                items: [
                  for (final b in Bucket.values)
                    DropdownMenuItem(
                      value: b,
                      child: Text(
                        b.name[0].toUpperCase() + b.name.substring(1),
                      ),
                    ),
                ],
                onChanged: (v) => setLocal(() => bucket = v ?? bucket),
                decoration: const InputDecoration(labelText: 'Bucket'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    final name = nameCtl.text.trim();
    nameCtl.dispose();
    if (added != true || name.isEmpty) return;
    if (_p.defFor(name) != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('"$name" already exists')));
      return;
    }
    await _save(
      PersonalCategories(
        customDefs: [
          ..._p.customDefs,
          CategoryDef(name: name, bucket: bucket, custom: true),
        ],
        rules: _p.rules,
      ),
    );
  }

  Future<void> _addRule() async {
    final kwCtl = TextEditingController();
    var category = _p.allDefs.first.name;
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add merchant rule'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: kwCtl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Keyword in the name',
                  hintText: 'e.g. landlord, gym, school',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: category,
                items: [
                  for (final d in _p.allDefs)
                    DropdownMenuItem(value: d.name, child: Text(d.name)),
                ],
                onChanged: (v) => setLocal(() => category = v ?? category),
                decoration: const InputDecoration(labelText: 'Category'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add rule'),
            ),
          ],
        ),
      ),
    );
    final kw = kwCtl.text.trim().toLowerCase();
    kwCtl.dispose();
    if (added != true || kw.isEmpty) return;
    await _save(
      PersonalCategories(
        customDefs: _p.customDefs,
        rules: {..._p.rules, kw: category},
      ),
    );
  }

  String _bucketLabel(Bucket b) => switch (b) {
    Bucket.needs => 'Needs',
    Bucket.wants => 'Wants',
    Bucket.savings => 'Savings',
  };

  /// v1.1: rename a custom category. Merchant rules pointing at
  /// the old name follow; the Shell migrates the budget cap and
  /// the alert state (spec §2.3).
  Future<void> _renameCategory(CategoryDef d) async {
    final ctl = TextEditingController(text: d.name);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename category'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    final name = ctl.text.trim();
    ctl.dispose();
    if (saved != true || name.isEmpty || name == d.name) return;
    if (_p.defFor(name) != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('"$name" already exists')));
      return;
    }
    await _save(
      PersonalCategories(
        customDefs: [
          for (final c in _p.customDefs)
            if (c.name == d.name)
              CategoryDef(name: name, bucket: c.bucket, custom: true)
            else
              c,
        ],
        rules: {
          for (final e in _p.rules.entries)
            e.key: e.value == d.name ? name : e.value,
        },
      ),
    );
    await widget.onRenameCategory?.call(d.name, name);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Categories')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        Text(
          'Your own rules are checked before the built-in ones.',
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              for (final d in _p.allDefs)
                ListTile(
                  title: Text(d.name),
                  subtitle: Text(_bucketLabel(d.bucket)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (d.custom)
                        Chip(
                          label: const Text('Custom'),
                          labelStyle: const TextStyle(fontSize: 10),
                          visualDensity: VisualDensity.compact,
                        ),
                      if (d.custom)
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          tooltip: 'Rename category',
                          onPressed: () => _renameCategory(d),
                        ),
                      if (d.custom)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: 'Delete category',
                          onPressed: () async {
                            await _save(
                              PersonalCategories(
                                customDefs: _p.customDefs
                                    .where((c) => c.name != d.name)
                                    .toList(),
                                rules: _p.rules,
                              ),
                            );
                            await widget.onDeleteCategory?.call(d.name);
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _addCategory,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add category'),
        ),
        const SizedBox(height: 18),
        Text('Merchant rules', style: KanakkuTheme.serif(size: 17)),
        const SizedBox(height: 4),
        Text(
          'If a sender or shop name contains the keyword, the entry lands in your category.',
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
        ),
        const SizedBox(height: 8),
        if (_p.rules.isEmpty)
          Text('No rules yet.', style: TextStyle(color: KanakkuTheme.inkSoft))
        else
          Card(
            child: Column(
              children: [
                for (final e in _p.rules.entries)
                  ListTile(
                    title: Text('"${e.key}" → ${e.value}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: 'Delete rule',
                      onPressed: () => _save(
                        PersonalCategories(
                          customDefs: _p.customDefs,
                          rules: {..._p.rules}..remove(e.key),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _addRule,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add merchant rule'),
        ),
      ],
    ),
  );
}

// =====================================================================
// v0.7 shared chrome: brand bar, text bottom nav, period selector,
// stat cards, and the statement import / analysis / PDF pages.
// =====================================================================

String greetingFor(DateTime now) {
  final h = now.hour;
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

/// Top brand bar (reference): teal dot logo + serif "Kanakku",
/// "PERSONAL FINANCE" letter-spaced caps on the right, gear for
/// Settings (app lock + daily summary live there).
class _BrandBar extends StatelessWidget {
  final VoidCallback onSettings;
  const _BrandBar({required this.onSettings});
  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
      child: Row(
        children: [
          Container(
            height: 26,
            width: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: KanakkuTheme.teal, width: 2),
            ),
            child: const Center(
              child: CircleAvatar(
                radius: 5,
                backgroundColor: KanakkuTheme.teal,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Kanakku',
            style: KanakkuTheme.serif(size: 24, color: KanakkuTheme.teal),
          ),
          const Spacer(),
          Text(
            'PERSONAL FINANCE',
            style: TextStyle(
              color: KanakkuTheme.inkSoft,
              fontSize: 10,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w600,
            ),
          ),
          IconButton(
            onPressed: onSettings,
            icon: Icon(
              Icons.settings_outlined,
              color: KanakkuTheme.inkSoft,
              size: 21,
            ),
            tooltip: 'Settings',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    ),
  );
}

/// Floating glass bottom bar (v1.0.1, iOS-style, from the
/// reference "More" tab): a frosted pill hovering over the page —
/// the shell sets extendBody, so scrolled content slides behind
/// the blur. All five destinations stay; icons return for the
/// footer only, flanking a raised circular Add button that
/// overlaps the pill's top edge and opens the Add sheet.
class _GlassBottomNav extends StatelessWidget {
  final int selected;
  final void Function(int) onSelect;
  final VoidCallback onAdd;
  const _GlassBottomNav({
    required this.selected,
    required this.onSelect,
    required this.onAdd,
  });

  /// (inactive icon, active icon, label) per destination, in tab
  /// order: Home · Transactions | + | Budgets · Insights · Splits.
  static const _items = <(IconData, IconData, String)>[
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.receipt_long_outlined, Icons.receipt_long, 'Transactions'),
    (
      Icons.account_balance_wallet_outlined,
      Icons.account_balance_wallet,
      'Budgets',
    ),
    (Icons.insights_outlined, Icons.insights, 'Insights'),
    (Icons.call_split_outlined, Icons.call_split, 'Splits'),
  ];

  Widget _item(int i) {
    final (off, on, label) = _items[i];
    final active = i == selected;
    final color = active ? KanakkuTheme.teal : KanakkuTheme.inkSoft;
    return Expanded(
      child: GestureDetector(
        key: ValueKey<String>('glass-nav-item-$i'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(active ? on : off, size: 22, color: color),
            const SizedBox(height: 2),
            // Single line, shrunk to fit: "Transactions" at 10.5px
            // is wider than its slot and used to WRAP (v1.0.2 fix),
            // which also made that item taller than the others.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 1),
            // The v1.0 teal dot, kept as the active marker. The
            // 4px slot is reserved in EVERY item (dot painted only
            // for the active one) so all five items share identical
            // geometry, active or not.
            SizedBox(
              height: 4,
              child: active
                  ? const CircleAvatar(
                      radius: 2,
                      backgroundColor: KanakkuTheme.teal,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final rim = KanakkuTheme.isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.35);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 14 + bottomInset),
      child: SizedBox(
        height: 78,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The frosted pill: shadowed, blurred, translucent.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      decoration: BoxDecoration(
                        color: KanakkuTheme.card.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: rim),
                      ),
                      // Two Expanded groups around a fixed 76px
                      // centre segment: flex 2 / flex 3 with every
                      // item itself Expanded, so all five slots
                      // are EXACTLY equal width — (pillWidth − 76)
                      // ÷ 5 each (v1.0.2 alignment fix, v1.0.3
                      // centre segment).
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Row(children: [_item(0), _item(1)]),
                          ),
                          const SizedBox(width: 76),
                          Expanded(
                            flex: 3,
                            child: Row(
                              children: [_item(2), _item(3), _item(4)],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Raised centre Add button, straddling the top edge.
            // v1.0.3: the button is centred in the bar's 76px
            // centre SEGMENT, not on the pill. With the 2-left /
            // 3-right split, the pill's own centre falls ~29px
            // inside the Budgets slot, so a pill-centred circle
            // (v1.0.1/v1.0.2) overlapped Budgets' icon. This
            // layer mirrors the pill row's exact segment geometry
            // (Spacer flex 2 · 76 · Spacer flex 3), so the 56px
            // circle sits centred in the segment with 10px
            // clearance each side — it can never touch a slot.
            Positioned.fill(
              child: Row(
                children: [
                  const Spacer(flex: 2),
                  SizedBox(
                    width: 76,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Material(
                        key: const ValueKey<String>('glass-nav-add'),
                        color: const Color(0xFF232323),
                        shape: const CircleBorder(),
                        elevation: 6,
                        shadowColor: Colors.black.withValues(alpha: 0.4),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onAdd,
                          child: const SizedBox(
                            width: 56,
                            height: 56,
                            child: Icon(
                              Icons.add,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(flex: 3),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "This month ▾" pill (reference). White, rounded, thin border.
class _PeriodSelector extends StatelessWidget {
  final PeriodSel period;
  final void Function(PeriodSel) onChanged;
  const _PeriodSelector({required this.period, required this.onChanged});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: KanakkuTheme.card,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: KanakkuTheme.dividerColor),
    ),
    child: PopupMenuButton<PeriodSel>(
      initialValue: period,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final p in PeriodSel.values)
          PopupMenuItem(value: p, child: Text(periodLabel(p))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              periodLabel(period),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.expand_more, size: 18),
          ],
        ),
      ),
    ),
  );
}

/// Big full-width teal button (reference "+ Add transaction").
class _TealButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _TealButton({required this.label, required this.onPressed});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: KanakkuTheme.teal,
        padding: const EdgeInsets.symmetric(vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onPressed,
      child: Text(
        label,
        style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
      ),
    ),
  );
}

/// One cell of the Home 2×2 stat grid. [filled] renders the teal
/// Net-cash-flow variant (white text on teal).
class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String sub;
  final Color? subColor;
  final bool filled;
  final double? progress;
  const _StatCard({
    required this.title,
    required this.value,
    required this.sub,
    this.subColor,
    this.filled = false,
    this.progress,
  });
  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: filled ? Colors.white70 : KanakkuTheme.inkSoft,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 5),
          // Big amounts shrink to fit on one line instead of
          // wrapping mid-number (v1.0.2: "₹6,59,313." / "18").
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              softWrap: false,
              style: KanakkuTheme.serif(
                size: 23,
                color: filled ? Colors.white : KanakkuTheme.ink,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            sub,
            style: TextStyle(
              color: filled
                  ? Colors.white70
                  : (subColor ?? KanakkuTheme.inkSoft),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress!.clamp(0, 1),
                minHeight: 6,
                backgroundColor: const Color(0xFFE4E9E7),
                color: KanakkuTheme.teal,
              ),
            ),
          ],
        ],
      ),
    );
    if (filled) {
      return Container(
        decoration: BoxDecoration(
          color: KanakkuTheme.tealHero,
          borderRadius: BorderRadius.circular(20),
        ),
        child: content,
      );
    }
    return Card(child: content);
  }
}

class _DottedCirclePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = KanakkuTheme.teal;
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 3;
    const dots = 26;
    for (var i = 0; i < dots; i++) {
      final a = (i / dots) * 2 * math.pi;
      canvas.drawCircle(
        Offset(center.dx + r * math.cos(a), center.dy + r * math.sin(a)),
        2.1,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Reference empty state: dotted circle + "No transactions yet".
class _EmptyTxns extends StatelessWidget {
  const _EmptyTxns();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CustomPaint(size: const Size(52, 52), painter: _DottedCirclePainter()),
        const SizedBox(height: 16),
        Text('No transactions yet', style: KanakkuTheme.serif(size: 20)),
        const SizedBox(height: 4),
        Text(
          'Add your first income or expense to get started.',
          style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
        ),
      ],
    ),
  );
}

/// Import preview (v0.7): what the CSV held, what will be skipped as
/// duplicates, and the Import button. Duplicates = same day + amount
/// + direction + overlapping description as an existing entry, or a
/// repeated row inside the same file.
class _ImportPreviewPage extends StatefulWidget {
  final List<StatementRow> rows;
  final List<String> existingKeys;
  final void Function(List<StatementRow>) onImport;
  const _ImportPreviewPage({
    required this.rows,
    required this.existingKeys,
    required this.onImport,
  });
  @override
  State<_ImportPreviewPage> createState() => _ImportPreviewPageState();
}

class _ImportPreviewPageState extends State<_ImportPreviewPage> {
  late final List<StatementRow> fresh;
  late final int dupCount;

  @override
  void initState() {
    super.initState();
    final seen = <String>[];
    final out = <StatementRow>[];
    var dups = 0;
    for (final r in widget.rows) {
      final key = statementDedupeKey(
        r.date,
        r.amount,
        r.isDebit,
        r.description,
      );
      final isDup =
          widget.existingKeys.any((k) => statementKeyMatches(k, key)) ||
          seen.any((k) => statementKeyMatches(k, key));
      if (isDup) {
        dups++;
      } else {
        out.add(r);
        seen.add(key);
      }
    }
    fresh = out;
    dupCount = dups;
  }

  @override
  Widget build(BuildContext context) {
    var totalIn = 0.0, totalOut = 0.0;
    DateTime? from, to;
    for (final r in widget.rows) {
      if (r.isDebit) {
        totalOut += r.amount;
      } else {
        totalIn += r.amount;
      }
      if (from == null || r.date.isBefore(from)) from = r.date;
      if (to == null || r.date.isAfter(to)) to = r.date;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Import statement')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.rows.length} transactions found',
                    style: KanakkuTheme.serif(size: 19),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    from != null ? '${_fmtDay(from)} – ${_fmtDay(to!)}' : '',
                    style: TextStyle(color: KanakkuTheme.inkSoft),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'In ${KanakkuTheme.inr(totalIn)} · Out ${KanakkuTheme.inr(totalOut)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (dupCount > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      '$dupCount look like duplicates of entries you already have — they will be skipped.',
                      style: TextStyle(
                        color: KanakkuTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                children: [
                  for (var i = 0; i < fresh.take(30).length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  fresh[i].description.isEmpty
                                      ? '—'
                                      : fresh[i].description,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  _fmtDay(fresh[i].date),
                                  style: TextStyle(
                                    color: KanakkuTheme.inkSoft,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '${fresh[i].isDebit ? '-' : '+'}${KanakkuTheme.inr(fresh[i].amount)}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: fresh[i].isDebit
                                  ? KanakkuTheme.debit
                                  : KanakkuTheme.credit,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (fresh.length > 30)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        '… and ${fresh.length - 30} more',
                        style: TextStyle(color: KanakkuTheme.inkSoft),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _TealButton(
            label: fresh.isEmpty
                ? 'Nothing new to import'
                : 'Import ${fresh.length} transactions',
            onPressed: fresh.isEmpty
                ? () => Navigator.of(context).pop(0)
                : () {
                    widget.onImport(fresh);
                    Navigator.of(context).pop(fresh.length);
                  },
          ),
        ],
      ),
    );
  }
}

/// Statement analysis (v0.7): computed from the imported statement
/// entries only — period totals, average daily spend, top
/// categories, top merchants, largest expenses.
class _StatementAnalysisPage extends StatelessWidget {
  final StatementAnalysis analysis;
  const _StatementAnalysisPage({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    Widget barRow(NamedTotal t) {
      final style = _catStyle(t.name);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  KanakkuTheme.inr(t.amount),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(t.share * 100).round()}%',
                  style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: t.share.clamp(0, 1),
                minHeight: 7,
                backgroundColor: style.$2.withValues(alpha: 0.14),
                color: style.$2,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Statement analysis')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          if (a.from != null)
            Text(
              '${_fmtDay(a.from!)} – ${_fmtDay(a.to!)} · ${a.count} transactions',
              style: TextStyle(color: KanakkuTheme.inkSoft),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  title: 'Total in',
                  value: KanakkuTheme.inr(a.totalIn),
                  sub: 'Credits',
                  subColor: KanakkuTheme.credit,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  title: 'Total out',
                  value: KanakkuTheme.inr(a.totalOut),
                  sub: 'Debits',
                  subColor: KanakkuTheme.debit,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  title: 'Net',
                  value: KanakkuTheme.inr(a.net),
                  sub: a.net >= 0 ? 'Kept' : 'Overspent',
                  filled: true,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  title: 'Avg daily spend',
                  value: KanakkuTheme.inr(a.avgDailySpend),
                  sub: 'Per day in period',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Top categories', style: KanakkuTheme.serif(size: 17)),
                  const SizedBox(height: 6),
                  if (a.topCategories.isEmpty)
                    Text(
                      'No spending in this statement.',
                      style: TextStyle(color: KanakkuTheme.inkSoft),
                    )
                  else
                    ...a.topCategories.map(barRow),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Top merchants', style: KanakkuTheme.serif(size: 17)),
                  const SizedBox(height: 6),
                  if (a.topMerchants.isEmpty)
                    Text(
                      'No spending in this statement.',
                      style: TextStyle(color: KanakkuTheme.inkSoft),
                    )
                  else
                    ...a.topMerchants.map(
                      (t) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                t.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              KanakkuTheme.inr(t.amount),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Largest expenses', style: KanakkuTheme.serif(size: 17)),
                  const SizedBox(height: 6),
                  if (a.largestExpenses.isEmpty)
                    Text(
                      'No expenses in this statement.',
                      style: TextStyle(color: KanakkuTheme.inkSoft),
                    )
                  else
                    ...a.largestExpenses.map(
                      (t) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.description.isEmpty ? '—' : t.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    _fmtDay(t.at),
                                    style: TextStyle(
                                      color: KanakkuTheme.inkSoft,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              KanakkuTheme.inr(t.amount),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: KanakkuTheme.debit,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PDF statements are accepted by the picker but not parsed in
/// this version — said plainly, with the way out.
class _PdfNoticePage extends StatelessWidget {
  const _PdfNoticePage();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Bank statement')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 52,
            width: 52,
            decoration: BoxDecoration(
              color: KanakkuTheme.tealSoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.picture_as_pdf_outlined,
              color: KanakkuTheme.teal,
              size: 26,
            ),
          ),
          const SizedBox(height: 16),
          Text('That was a PDF statement', style: KanakkuTheme.serif(size: 21)),
          const SizedBox(height: 8),
          const Text(
            'PDF statements can\'t be read yet — download the CSV/Excel statement from your bank app and upload that.',
            style: TextStyle(fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 6),
          Text(
            'In your bank app, look for Statements → Download → CSV format. (Excel files can\'t be read yet either — CSV is the one that works.)',
            style: TextStyle(color: KanakkuTheme.inkSoft, fontSize: 13),
          ),
          const SizedBox(height: 20),
          _TealButton(
            label: 'Got it',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ),
  );
}
