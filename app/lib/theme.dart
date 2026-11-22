import 'package:flutter/material.dart';

/// Kanakku design system.
///
/// v1.2 "Reference" redesign (Guna's order, 22 Nov 2026 — spec:
/// docs/REDESIGN-SPEC.md): warm light-grey background, pure-white
/// cards with a 24px radius, deep-green primary, pastel sage tints
/// for chart bars and icon tiles, pill badges, and clean-sans bold
/// amounts. The token NAMES from the v0.7 "MyWallet" language are
/// kept (teal/card/cream/ink…) so every existing call site follows
/// the new palette without a per-widget refactor; [serif] likewise
/// survives for the not-yet-reskinned screens (Phase 3), while new
/// v1.2 surfaces use [amount]/[sectionTitle] sans styles.
///
/// Appearance settings (v1.0): the surface colours (cream, card,
/// ink, inkSoft) are getters driven by [applyAppearance] so the
/// whole app follows Light/Dark/Device. [noDecimals] and [hour24]
/// are the Decimal/Time format settings, honoured by
/// [inr]/[inrCompact] and [fmtTimeOfDay].
class KanakkuTheme {
  /// v1.2 deep green — the primary/accent everywhere. [teal] is
  /// kept as the historical name; it IS the new green now.
  static const primary = Color(0xFF1E6B4F);
  static const primaryDark = Color(0xFF14523C);
  static const teal = primary;
  static const tealDark = primaryDark;
  static const tealHero = primary;
  static const tealMint = Color(0xFFB9D6C6);
  static const tealSoft = Color(0xFFE1EDE5);

  /// Pastel sage for inactive chart bars / soft fills (reference:
  /// pale green-grey bars, the current month in deep green).
  static const sage = Color(0xFFC2D6CB);
  static const sageDeep = primary;

  /// Card geometry (v1.2): very rounded white cards, icon tiles a
  /// step squarer.
  static const cardRadius = 24.0;
  static const tileRadius = 16.0;

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

  /// Serif display style for page titles / hero numbers / headings
  /// on screens not yet reskinned to v1.2 (Phase 3 removes most).
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

  /// v1.2 big-number style: clean sans, extra-bold — the reference
  /// renders amounts this way (₹5,969.83, ₹22,858).
  static TextStyle amount({
    double size = 24,
    Color? color,
    FontWeight weight = FontWeight.w800,
  }) => TextStyle(
    fontFamily: sansFamily,
    fontFamilyFallback: tamilFallback,
    fontSize: size,
    fontWeight: weight,
    color: color ?? ink,
    letterSpacing: -0.3,
  );

  /// v1.2 section heading ("Monthly Spending", "Subscriptions").
  static TextStyle sectionTitle({double size = 17, Color? color}) =>
      TextStyle(
        fontFamily: sansFamily,
        fontFamilyFallback: tamilFallback,
        fontSize: size,
        fontWeight: FontWeight.w800,
        color: color ?? ink,
      );

  /// Grey secondary line under titles / amounts.
  static TextStyle secondary({double size = 13, Color? color}) => TextStyle(
    fontFamily: sansFamily,
    fontFamilyFallback: tamilFallback,
    fontSize: size,
    color: color ?? inkSoft,
  );

  /// Legacy names kept as aliases so older call sites follow the
  /// palette shift automatically.
  static const orange = teal;
  static const orangeSoft = tealSoft;

  // ---- appearance state (v1.0) ------------------------------------
  static bool _dark = false;
  static bool get isDark => _dark;

  /// Called by the app root whenever the effective brightness
  /// changes (Light / Dark / Device setting).
  static void applyAppearance(bool dark) => _dark = dark;

  /// Warm light-grey page background (light) / warm charcoal (dark).
  static Color get cream =>
      _dark ? const Color(0xFF131613) : const Color(0xFFF3F3F0);
  static Color get card => _dark ? const Color(0xFF1F2420) : Colors.white;
  static Color get ink =>
      _dark ? const Color(0xFFEDF2EE) : const Color(0xFF1C1E1C);
  static Color get inkSoft =>
      _dark ? const Color(0xFFA3ADA4) : const Color(0xFF6F7268);

  /// Soft neutral fill used for chips / wells on cards.
  static Color get surfaceAlt =>
      _dark ? const Color(0xFF2A2F2B) : const Color(0xFFECECE8);

  /// v1.2 text-field well (Phase 3): soft neutral fill, 16px
  /// radius, no border — the Add / Split / edit surfaces type into
  /// these instead of underlined Material fields.
  static InputDecoration wellDecoration({
    String? label,
    String? hint,
    String? prefix,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    prefixText: prefix,
    filled: true,
    fillColor: surfaceAlt,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: primary, width: 1.5),
    ),
  );

  /// v1.2 pill chip style for ChoiceChips (Phase 3): stadium
  /// shape, no outline, soft selected label. Colours still come
  /// from the chip's own selectedColor/backgroundColor arguments.
  static const chipShape = StadiumBorder();
  static BorderSide get chipSide => BorderSide(color: dividerColor);
  static Color get progressTrack =>
      _dark ? const Color(0xFF2A2F2B) : const Color(0xFFE3EAE5);
  static Color get dividerColor =>
      _dark ? const Color(0xFF2A2F2B) : const Color(0xFFE6E6E0);

  // ---- pill badges (v1.2) ------------------------------------------
  // Reference: "8 Active" (grey), "4 Payments" (amber tint),
  // "↑40%" (pink tint), "Active"/"Renews" (green tint).
  static Color get badgeGreyBg =>
      _dark ? const Color(0xFF2A2F2B) : const Color(0xFFF0F0EC);
  static Color get badgeGreyFg =>
      _dark ? const Color(0xFFB9C0BA) : const Color(0xFF6F7268);
  static Color get badgeAmberBg =>
      _dark ? const Color(0xFF3A2F16) : const Color(0xFFF8ECD2);
  static Color get badgeAmberFg =>
      _dark ? const Color(0xFFE3B959) : const Color(0xFF96690F);
  static Color get badgePinkBg =>
      _dark ? const Color(0xFF3B2020) : const Color(0xFFFBE4E4);
  static Color get badgePinkFg =>
      _dark ? const Color(0xFFF09696) : const Color(0xFFC13B3B);
  static Color get badgeGreenBg =>
      _dark ? const Color(0xFF1D3325) : const Color(0xFFDFF2E4);
  static Color get badgeGreenFg =>
      _dark ? const Color(0xFF7ED598) : const Color(0xFF1E7A46);

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

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final base = brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    return base.copyWith(
      // Manrope is the app-wide default typeface.
      textTheme: base.textTheme.apply(
        fontFamily: sansFamily,
        fontFamilyFallback: tamilFallback,
      ),
      scaffoldBackgroundColor: cream,
      colorScheme: base.colorScheme.copyWith(
        primary: primary,
        surface: card,
        onSurface: ink,
        brightness: brightness,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: cream,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: sansFamily,
          fontFamilyFallback: tamilFallback,
          color: ink,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
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

/// v1.2 white card: pure-white surface (dark: card colour), 24px
/// radius, no shadow — the reference's card language. [onTap] makes
/// the whole card tappable with a matching ink ripple clipped to
/// the radius.
class KCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  const KCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The child sits on its own transparent Material so a ListTile
    // inside a KCard paints its ink on it instead of tripping the
    // "ListTile under a coloured DecoratedBox" assertion (Phase 3).
    final box = Container(
      decoration: BoxDecoration(
        color: KanakkuTheme.card,
        borderRadius: BorderRadius.circular(KanakkuTheme.cardRadius),
      ),
      padding: padding,
      child: Material(type: MaterialType.transparency, child: child),
    );
    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KanakkuTheme.cardRadius),
        child: box,
      ),
    );
  }
}

/// v1.2 pill badge: small rounded label on a tinted ground
/// ("8 Active", "4 Payments", "↑ 40%", "Active"…). Colours come
/// from the KanakkuTheme.badge* tokens.
class PillBadge extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;
  const PillBadge({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 3),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ),
      ],
    ),
  );
}

/// v1.2 rounded progress bar: green fill on a pale track, fully
/// rounded ends (budget rows, subscription cycle progress).
class RoundedProgress extends StatelessWidget {
  final double value; // 0..1
  final Color? color;
  final double height;
  const RoundedProgress({
    super.key,
    required this.value,
    this.color,
    this.height = 7,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(999),
    child: LinearProgressIndicator(
      value: value.clamp(0, 1).toDouble(),
      minHeight: height,
      backgroundColor: KanakkuTheme.progressTrack,
      color: color ?? KanakkuTheme.primary,
    ),
  );
}

/// v1.2 page header (Phase 3): big bold sans title + grey
/// sub-line — replaces the serif page titles on the reskinned
/// Transactions / Budgets / Insights / Splits pages.
class KPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  const KPageHeader({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: KanakkuTheme.sectionTitle(size: 26)),
      if (subtitle != null) ...[
        const SizedBox(height: 4),
        Text(subtitle!, style: KanakkuTheme.secondary(size: 14)),
      ],
    ],
  );
}

/// v1.2 tinted icon tile (Phase 3): soft pastel square with a
/// 16px radius holding a category/brand icon — the row leading
/// element across lists and settings rows.
class KIconTile extends StatelessWidget {
  final IconData icon;
  final Color background;
  final Color foreground;
  final double size;
  final double iconSize;
  const KIconTile({
    super.key,
    required this.icon,
    required this.background,
    required this.foreground,
    this.size = 44,
    this.iconSize = 21,
  });

  @override
  Widget build(BuildContext context) => Container(
    height: size,
    width: size,
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(KanakkuTheme.tileRadius),
    ),
    child: Icon(icon, color: foreground, size: iconSize),
  );
}
