import 'package:flutter/material.dart';

/// Kanakku design system — v0.7 "MyWallet" design language:
/// pale mint-grey background, white cards with ~20px radius, deep
/// teal primary, and a serif display font for the wordmark, page
/// titles and big numbers — Fraunces since v1.0.3 (bundled Noto
/// Serif before), with Manrope as the app-wide UI sans.
///
/// v1.0: appearance settings. The four surface colours (cream, card,
/// ink, inkSoft) are getters driven by [applyAppearance] so the whole
/// app — which references them everywhere — follows Light/Dark/Device
/// without a per-widget refactor. [noDecimals] and [hour24] are the
/// Decimal/Time format settings, honoured by [inr]/[inrCompact] and
/// [fmtTimeOfDay].
class KanakkuTheme {
  static const teal = Color(0xFF0B6E63);
  static const tealDark = Color(0xFF095C52);
  static const tealHero = Color(0xFF0E7569);
  static const tealMint = Color(0xFFBFE6DC);
  static const tealSoft = Color(0xFFDEF3EE);

  /// Bundled font families (see pubspec fonts), v1.0.3:
  /// [displayFamily] is Fraunces (500/600/700/900 — requested
  /// weights resolve to the nearest cut), [sansFamily] is Manrope
  /// and is the app-wide default via the ThemeData text themes.
  static const displayFamily = 'KanakkuDisplay';
  static const sansFamily = 'KanakkuSans';

  /// Tamil fallback for bundled-font styles: neither Fraunces nor
  /// Manrope carries Tamil glyphs, so Tamil strings fall back to
  /// the platform's Noto Sans Tamil (named explicitly; Android's
  /// system fallback chain covers it regardless).
  static const tamilFallback = <String>['Noto Sans Tamil'];

  /// Serif display style for page titles / hero numbers / headings.
  static TextStyle serif({
    double size = 20,
    FontWeight weight = FontWeight.w700,
    Color? color,
    double? height,
  }) => TextStyle(
    fontFamily: displayFamily,
    fontFamilyFallback: const [...tamilFallback, 'serif'],
    fontSize: size,
    fontWeight: weight,
    color: color ?? ink,
    height: height,
  );

  /// Legacy names kept as aliases so older call sites follow the
  /// teal shift automatically.
  static const orange = teal;
  static const orangeSoft = tealSoft;

  // ---- appearance state (v1.0) ------------------------------------
  static bool _dark = false;
  static bool get isDark => _dark;

  /// Called by the app root whenever the effective brightness
  /// changes (Light / Dark / Device setting).
  static void applyAppearance(bool dark) => _dark = dark;

  /// Pale mint-grey page background (light) / deep mint-charcoal (dark).
  static Color get cream =>
      _dark ? const Color(0xFF101915) : const Color(0xFFEFF5F2);
  static Color get card => _dark ? const Color(0xFF1D2A24) : Colors.white;
  static Color get ink =>
      _dark ? const Color(0xFFEDF3F0) : const Color(0xFF1C1917);
  static Color get inkSoft =>
      _dark ? const Color(0xFF9DB3A9) : const Color(0xFF78716C);

  /// Soft neutral fill used for chips / wells on cards.
  static Color get surfaceAlt =>
      _dark ? const Color(0xFF2A3831) : const Color(0xFFF5F5F4);
  static Color get progressTrack =>
      _dark ? const Color(0xFF2A3831) : const Color(0xFFE4E9E7);
  static Color get dividerColor =>
      _dark ? const Color(0xFF2A3831) : const Color(0xFFE1EAE5);

  static const needs = teal;
  static const wants = Color(0xFFF59E0B);
  static const savings = Color(0xFF22C55E);
  static const debit = Color(0xFFDC2626);
  static const credit = Color(0xFF16A34A);

  // ---- format settings (v1.0) --------------------------------------
  /// Decimal Format setting: true → amounts render with no decimals
  /// (₹1,235 instead of ₹1,234.56).
  static bool noDecimals = false;

  /// Time Format setting: true → 24-hour clock in rendered times.
  static bool hour24 = false;

  /// "9:00 PM" (12h) or "21:00" (24h) for a wall-clock time.
  static String fmtTimeOfDay(int hour, int minute) {
    final mm = minute.toString().padLeft(2, '0');
    if (hour24) return '${hour.toString().padLeft(2, '0')}:$mm';
    final suffix = hour < 12 ? 'AM' : 'PM';
    var h = hour % 12;
    if (h == 0) h = 12;
    return '$h:$mm $suffix';
  }

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      // v1.0.3: Manrope is the app-wide default typeface.
      textTheme: base.textTheme.apply(
        fontFamily: sansFamily,
        fontFamilyFallback: tamilFallback,
      ),
      scaffoldBackgroundColor: cream,
      colorScheme: base.colorScheme.copyWith(
        primary: teal,
        surface: card,
        onSurface: ink,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: cream,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: teal,
        foregroundColor: Colors.white,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: card,
        indicatorColor: tealSoft,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      // v1.0.3: Manrope is the app-wide default typeface.
      textTheme: base.textTheme.apply(
        fontFamily: sansFamily,
        fontFamilyFallback: tamilFallback,
      ),
      scaffoldBackgroundColor: cream,
      colorScheme: base.colorScheme.copyWith(
        primary: teal,
        surface: card,
        onSurface: ink,
        brightness: Brightness.dark,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: cream,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: teal,
        foregroundColor: Colors.white,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: card,
        indicatorColor: tealSoft,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      dividerColor: dividerColor,
    );
  }

  static String inr(double v) {
    final neg = v < 0;
    final fixed = noDecimals ? 0 : (v.abs() % 1 == 0 ? 0 : 2);
    final s = v.abs().toStringAsFixed(fixed);
    final parts = s.split('.');
    var whole = parts[0];
    // Indian digit grouping (last 3, then pairs)
    if (whole.length > 3) {
      final tail = whole.substring(whole.length - 3);
      var head = whole.substring(0, whole.length - 3);
      final buf = <String>[];
      while (head.length > 2) {
        buf.insert(0, head.substring(head.length - 2));
        head = head.substring(0, head.length - 2);
      }
      if (head.isNotEmpty) buf.insert(0, head);
      whole = '${buf.join(',')},$tail';
    }
    return '${neg ? '-' : ''}₹$whole${parts.length > 1 ? '.${parts[1]}' : ''}';
  }

  /// Compact ₹ format from the reference UI: ₹950 stays as-is,
  /// ₹7,800 → "₹7.8k", ₹12,500 → "₹12.5k", ₹1,20,000 → "₹1.2L".
  /// Trailing ".0" is trimmed (₹7,000 → "₹7k", ₹1,00,000 → "₹1L").
  /// With the No-decimals format setting the fraction is dropped
  /// entirely (₹7.8k → "₹7k").
  static String inrCompact(double v) {
    final neg = v < 0;
    final a = v.abs();
    if (a < 1000) return inr(v);
    String trimmed(double x) {
      if (noDecimals) return x.floor().toString();
      final s = x.toStringAsFixed(1);
      return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    }

    final body = a < 100000
        ? '₹${trimmed(a / 1000)}k'
        : '₹${trimmed(a / 100000)}L';
    return neg ? '-$body' : body;
  }
}
