/// App settings (v1.0 "Options pack"). One JSON document persisted
/// natively in the settings_store (CaptureStore pattern) and loaded
/// at startup by the Shell. Every field has the pre-v1.0 behaviour
/// as its default, so a missing/partial document changes nothing.
library;

import 'dart:convert';

import 'manual.dart' show incomeTypes;

/// Payment modes offered in the Add sheet and as a default.
const paymentModes = <String>['Cash', 'UPI', 'Card', 'Bank Transfer'];

/// Expense subcategory options across all buckets (the Add sheet's
/// lists) — the choices for "Default Expense Category".
const expenseCategoryOptions = <String>[
  'Groceries',
  'Rent',
  'Utilities',
  'Travel',
  'Health',
  'Food Delivery',
  'Shopping',
  'Entertainment',
  'Subscriptions',
  'Investments',
  'Emergency Fund',
];

class KanakkuSettings {
  final String profileName;
  final String defaultPaymentMode;
  final String defaultExpenseCategory;
  final String defaultIncomeCategory;
  final int monthStartDay; // 1..28
  final String weekStartsOn; // 'Monday' | 'Sunday'
  final String homeBalanceView; // 'net' | 'accounts'
  final bool haptics;
  final String themeMode; // 'light' | 'dark' | 'device'
  final String timeFormat; // '12h' | '24h'
  final String decimalFormat; // 'full' | 'none'
  final bool dailyReminderOn;
  final int dailyReminderHour; // local wall clock
  final int dailyReminderMinute;
  final bool balancePrivacy;
  final int? lastBackupAt; // millis since epoch

  // v1.1 (spec §2.4): budget alerts + biometric unlock.
  final int? overallMonthlyCapPaise; // null = overall alerts off
  final bool budgetAlertsOn;
  final bool biometricUnlock;

  const KanakkuSettings({
    this.profileName = 'Guna',
    this.defaultPaymentMode = 'Cash',
    this.defaultExpenseCategory = 'Groceries',
    this.defaultIncomeCategory = 'Salary',
    this.monthStartDay = 1,
    this.weekStartsOn = 'Monday',
    this.homeBalanceView = 'net',
    this.haptics = true,
    this.themeMode = 'device',
    this.timeFormat = '12h',
    this.decimalFormat = 'full',
    this.dailyReminderOn = true,
    this.dailyReminderHour = 21,
    this.dailyReminderMinute = 0,
    this.balancePrivacy = false,
    this.lastBackupAt,
    this.overallMonthlyCapPaise,
    this.budgetAlertsOn = true,
    this.biometricUnlock = false,
  });

  KanakkuSettings copyWith({
    String? profileName,
    String? defaultPaymentMode,
    String? defaultExpenseCategory,
    String? defaultIncomeCategory,
    int? monthStartDay,
    String? weekStartsOn,
    String? homeBalanceView,
    bool? haptics,
    String? themeMode,
    String? timeFormat,
    String? decimalFormat,
    bool? dailyReminderOn,
    int? dailyReminderHour,
    int? dailyReminderMinute,
    bool? balancePrivacy,
    int? lastBackupAt,
    bool clearLastBackupAt = false,
    int? overallMonthlyCapPaise,
    bool clearOverallMonthlyCap = false,
    bool? budgetAlertsOn,
    bool? biometricUnlock,
  }) => KanakkuSettings(
    profileName: profileName ?? this.profileName,
    defaultPaymentMode: defaultPaymentMode ?? this.defaultPaymentMode,
    defaultExpenseCategory:
        defaultExpenseCategory ?? this.defaultExpenseCategory,
    defaultIncomeCategory: defaultIncomeCategory ?? this.defaultIncomeCategory,
    monthStartDay: monthStartDay ?? this.monthStartDay,
    weekStartsOn: weekStartsOn ?? this.weekStartsOn,
    homeBalanceView: homeBalanceView ?? this.homeBalanceView,
    haptics: haptics ?? this.haptics,
    themeMode: themeMode ?? this.themeMode,
    timeFormat: timeFormat ?? this.timeFormat,
    decimalFormat: decimalFormat ?? this.decimalFormat,
    dailyReminderOn: dailyReminderOn ?? this.dailyReminderOn,
    dailyReminderHour: dailyReminderHour ?? this.dailyReminderHour,
    dailyReminderMinute: dailyReminderMinute ?? this.dailyReminderMinute,
    balancePrivacy: balancePrivacy ?? this.balancePrivacy,
    lastBackupAt: clearLastBackupAt
        ? null
        : (lastBackupAt ?? this.lastBackupAt),
    overallMonthlyCapPaise: clearOverallMonthlyCap
        ? null
        : (overallMonthlyCapPaise ?? this.overallMonthlyCapPaise),
    budgetAlertsOn: budgetAlertsOn ?? this.budgetAlertsOn,
    biometricUnlock: biometricUnlock ?? this.biometricUnlock,
  );

  Map<String, dynamic> toJson() => {
    'profileName': profileName,
    'defaultPaymentMode': defaultPaymentMode,
    'defaultExpenseCategory': defaultExpenseCategory,
    'defaultIncomeCategory': defaultIncomeCategory,
    'monthStartDay': monthStartDay,
    'weekStartsOn': weekStartsOn,
    'homeBalanceView': homeBalanceView,
    'haptics': haptics,
    'themeMode': themeMode,
    'timeFormat': timeFormat,
    'decimalFormat': decimalFormat,
    'dailyReminderOn': dailyReminderOn,
    'dailyReminderHour': dailyReminderHour,
    'dailyReminderMinute': dailyReminderMinute,
    'balancePrivacy': balancePrivacy,
    'lastBackupAt': lastBackupAt,
    'overallMonthlyCapPaise': overallMonthlyCapPaise,
    'budgetAlertsOn': budgetAlertsOn,
    'biometricUnlock': biometricUnlock,
  };

  factory KanakkuSettings.fromJson(Map<String, dynamic> j) {
    String str(String k, String d) {
      final v = j[k]?.toString();
      return (v == null || v.isEmpty) ? d : v;
    }

    bool flag(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    const d = KanakkuSettings();
    final mode = str('defaultPaymentMode', d.defaultPaymentMode);
    final expCat = str('defaultExpenseCategory', d.defaultExpenseCategory);
    final incCat = str('defaultIncomeCategory', d.defaultIncomeCategory);
    var startDay = (j['monthStartDay'] as num?)?.toInt() ?? d.monthStartDay;
    if (startDay < 1 || startDay > 28) startDay = 1;
    final hour = (j['dailyReminderHour'] as num?)?.toInt() ?? 21;
    final minute = (j['dailyReminderMinute'] as num?)?.toInt() ?? 0;
    return KanakkuSettings(
      profileName: str('profileName', d.profileName),
      defaultPaymentMode: paymentModes.contains(mode)
          ? mode
          : d.defaultPaymentMode,
      defaultExpenseCategory: expenseCategoryOptions.contains(expCat)
          ? expCat
          : d.defaultExpenseCategory,
      defaultIncomeCategory: incomeTypes.contains(incCat)
          ? incCat
          : d.defaultIncomeCategory,
      monthStartDay: startDay,
      weekStartsOn: str('weekStartsOn', d.weekStartsOn) == 'Sunday'
          ? 'Sunday'
          : 'Monday',
      homeBalanceView: str('homeBalanceView', d.homeBalanceView) == 'accounts'
          ? 'accounts'
          : 'net',
      haptics: flag('haptics', d.haptics),
      themeMode:
          const [
            'light',
            'dark',
            'device',
          ].contains(str('themeMode', d.themeMode))
          ? str('themeMode', d.themeMode)
          : d.themeMode,
      timeFormat: str('timeFormat', d.timeFormat) == '24h' ? '24h' : '12h',
      decimalFormat: str('decimalFormat', d.decimalFormat) == 'none'
          ? 'none'
          : 'full',
      dailyReminderOn: flag('dailyReminderOn', d.dailyReminderOn),
      dailyReminderHour: (hour >= 0 && hour <= 23) ? hour : 21,
      dailyReminderMinute: (minute >= 0 && minute <= 59) ? minute : 0,
      balancePrivacy: flag('balancePrivacy', d.balancePrivacy),
      lastBackupAt: (j['lastBackupAt'] as num?)?.toInt(),
      // v1.1 (spec §2.4): decode-with-defaults; a negative or
      // non-numeric cap reads as "not set" (overall alerts off).
      overallMonthlyCapPaise: () {
        final v = (j['overallMonthlyCapPaise'] as num?)?.toInt();
        return (v != null && v > 0) ? v : null;
      }(),
      budgetAlertsOn: flag('budgetAlertsOn', d.budgetAlertsOn),
      biometricUnlock: flag('biometricUnlock', d.biometricUnlock),
    );
  }
}

String encodeSettings(KanakkuSettings s) => jsonEncode(s.toJson());

KanakkuSettings decodeSettings(String json) {
  try {
    final map = jsonDecode(json);
    if (map is Map) {
      return KanakkuSettings.fromJson(Map<String, dynamic>.from(map));
    }
  } catch (_) {}
  return const KanakkuSettings();
}
