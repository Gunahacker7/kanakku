import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/main.dart';
import 'package:kanakku/backup.dart';
import 'package:kanakku/categories.dart';
import 'package:kanakku/manual.dart';
import 'package:kanakku/settings.dart';
import 'package:kanakku/theme.dart';
import 'package:kanakku_parser/categorize.dart';
import 'package:kanakku_parser/kanakku_parser.dart' show TxnDirection;

void main() {
  group('settings round-trip', () {
    test('defaults survive encode/decode unchanged', () {
      const s = KanakkuSettings();
      final back = decodeSettings(encodeSettings(s));
      expect(back.toJson(), s.toJson());
    });

    test('a full custom document round-trips and validates', () {
      const s = KanakkuSettings(
        profileName: 'Vaishnavi',
        defaultPaymentMode: 'UPI',
        defaultExpenseCategory: 'Travel',
        defaultIncomeCategory: 'Bonus',
        monthStartDay: 15,
        weekStartsOn: 'Sunday',
        homeBalanceView: 'accounts',
        haptics: false,
        themeMode: 'dark',
        timeFormat: '24h',
        decimalFormat: 'none',
        dailyReminderOn: false,
        dailyReminderHour: 7,
        dailyReminderMinute: 30,
        balancePrivacy: true,
        lastBackupAt: 123456789,
      );
      final back = decodeSettings(encodeSettings(s));
      expect(back.toJson(), s.toJson());
    });

    test('junk values fall back to safe defaults', () {
      final s = decodeSettings(
        '{"monthStartDay": 31, "defaultPaymentMode": "Barter", '
        '"themeMode": "purple", "dailyReminderHour": 99}',
      );
      expect(s.monthStartDay, 1);
      expect(s.defaultPaymentMode, 'Cash');
      expect(s.themeMode, 'device');
      expect(s.dailyReminderHour, 21);
      expect(decodeSettings('not json').profileName, 'Guna');
    });
  });

  group('monthStartDay period boundaries (start day 15)', () {
    test('month window mid-window', () {
      final (s, e) = monthWindow(DateTime(2026, 10, 20), 15);
      expect(s, DateTime(2026, 10, 15));
      expect(e, DateTime(2026, 11, 15));
    });

    test('month window before the start day belongs to last window', () {
      final (s, e) = monthWindow(DateTime(2026, 10, 3), 15);
      expect(s, DateTime(2026, 9, 15));
      expect(e, DateTime(2026, 10, 15));
    });

    test('year rollover', () {
      final (s, e) = monthWindow(DateTime(2027, 1, 2), 15);
      expect(s, DateTime(2026, 12, 15));
      expect(e, DateTime(2027, 1, 15));
    });

    test('periodRange this/last month with start day 15', () {
      final now = DateTime(2026, 10, 20);
      expect(periodRange(PeriodSel.thisMonth, now, 15), (
        DateTime(2026, 10, 15),
        DateTime(2026, 11, 15),
      ));
      expect(periodRange(PeriodSel.lastMonth, now, 15), (
        DateTime(2026, 9, 15),
        DateTime(2026, 10, 15),
      ));
    });

    test('start day 1 is the plain calendar month', () {
      final now = DateTime(2026, 10, 20);
      expect(periodRange(PeriodSel.thisMonth, now), (
        DateTime(2026, 10),
        DateTime(2026, 11),
      ));
      expect(periodRange(PeriodSel.lastMonth, now, 1), (
        DateTime(2026, 9),
        DateTime(2026, 10),
      ));
    });
  });

  group('backup / restore', () {
    test('backup map survives encode → parse with stores intact', () {
      final stores = {
        'manual': '[{"amount": 100.0, "label": "Groceries"}]',
        'removed': '[]',
        'splits': '[{"id": "x"}]',
        'budgets': '{"Groceries": 6000.0}',
        'statement': '[]',
        'categories': '{"custom": [], "rules": {"gym": "Health"}}',
        // v1.1 (spec §6.2): backups carry the recurring document
        // inside the same envelope.
        'recurring': '{"nextRuleSeq":1,"rules":[]}',
      };
      final settings = const KanakkuSettings(profileName: 'Guna').toJson();
      final backup = buildBackup(
        stores: stores,
        settings: settings,
        createdAt: DateTime(2026, 10, 29),
      );
      final parsed = parseBackup(encodeBackup(backup));
      expect(parsed, isNotNull);
      expect(parsed!.stores, stores);
      expect(parsed.settings, settings);
      // And the whole document round-trips through JSON untouched.
      final again = buildBackup(
        stores: parsed.stores,
        settings: parsed.settings!,
        createdAt: DateTime.fromMillisecondsSinceEpoch(backup['createdAt']),
      );
      expect(jsonEncode(again), jsonEncode(backup));
    });

    test('foreign or future-version files are rejected', () {
      expect(parseBackup('{"app": "other", "formatVersion": 1}'), isNull);
      expect(
        parseBackup(
          '{"app": "kanakku", "formatVersion": 99, "stores": {"manual": "[]"}}',
        ),
        isNull,
      );
      expect(parseBackup('not json at all'), isNull);
      expect(parseBackup('{"app": "kanakku", "formatVersion": 1}'), isNull);
    });

    test('encrypted envelope is detected, not parsed as stores (v1.0.4)', () {
      // Native crypto is device-verified; what Dart owns is the
      // envelope shape: parseBackup must surface the blob and NO
      // stores, so a restore writes nothing before decryption.
      final envelope = buildEncryptedBackup(
        data: 'c2FsdGl2Y2lwaGVydGV4dA==',
        createdAt: DateTime(2026, 10, 29),
      );
      final parsed = parseBackup(encodeBackup(envelope));
      expect(parsed, isNotNull);
      expect(parsed!.encryptedBlob, 'c2FsdGl2Y2lwaGVydGV4dA==');
      expect(parsed.stores, isEmpty);
      expect(parsed.settings, isNull);
      // Malformed envelopes are rejected outright.
      expect(
        parseBackup(
          '{"app": "kanakku", "formatVersion": 2, "enc": true}',
        ),
        isNull,
      );
      expect(
        parseBackup(
          '{"app": "kanakku", "formatVersion": 2, "data": "x"}',
        ),
        isNull,
      );
      expect(
        parseBackup(
          '{"app": "kanakku", "formatVersion": 2, "enc": true, "data": ""}',
        ),
        isNull,
      );
      // Plain backups keep parsing with a null blob.
      final plain = parseBackup(
        '{"app": "kanakku", "formatVersion": 1, "stores": {"manual": "[]"}}',
      );
      expect(plain, isNotNull);
      expect(plain!.encryptedBlob, isNull);
    });
  });

  group('personal categories', () {
    test('a personal rule beats the built-in merchant table', () {
      const personal = PersonalCategories(rules: {'swiggy': 'Rent'});
      final hit = categorizePersonal('SWIGGY ORDER', personal);
      expect(hit?.category, 'Rent');
      expect(hit?.bucket, Bucket.needs);
      // Built-in would have said Food Delivery / wants.
      expect(categorize('SWIGGY ORDER')?.category, 'Food Delivery');
    });

    test('custom category bucket comes from its def', () {
      const personal = PersonalCategories(
        customDefs: [CategoryDef(name: 'Gym', bucket: Bucket.needs)],
        rules: {'cultfit': 'Gym'},
      );
      final hit = categorizePersonal('CULTFIT PASS', personal);
      expect(hit?.category, 'Gym');
      expect(hit?.bucket, Bucket.needs);
    });

    test('no rule → built-in behaviour; store round-trips', () {
      const personal = PersonalCategories(
        customDefs: [CategoryDef(name: 'Pets', bucket: Bucket.wants)],
        rules: {'vet': 'Pets'},
      );
      expect(categorizePersonal('ZOMATO', personal)?.category, 'Food Delivery');
      final back = decodeCategories(encodeCategories(personal));
      expect(back.rules, personal.rules);
      expect(back.customDefs.single.name, 'Pets');
      expect(back.defFor('Food Delivery')?.bucket, Bucket.wants);
      expect(back.allDefs.length, defaultCategoryDefs().length + 1);
    });
  });

  group('tags + manual mode/tag persistence', () {
    test('mode and tag ride the manual JSON and reload', () {
      final at = DateTime(2026, 10, 29, 12);
      final json = manualToJson(
        amount: 250,
        label: 'Groceries',
        at: at,
        direction: TxnDirection.debit,
        mode: 'UPI',
        tag: 'Home',
      );
      expect(manualModeFromJson(json), 'UPI');
      expect(manualTagFromJson(json), 'Home');
      final legacy = manualToJson(
        amount: 1,
        label: 'X',
        at: at,
        direction: TxnDirection.debit,
      );
      expect(legacy.containsKey('mode'), isFalse);
      expect(legacy.containsKey('tag'), isFalse);
      expect(manualModeFromJson(legacy), isNull);
      expect(manualTagFromJson(legacy), isNull);
    });

    test('distinct tags + filter predicate', () {
      expect(distinctTags(['Home', null, 'Trip', 'Home', ' ', '']), [
        'Home',
        'Trip',
      ]);
      expect(tagFilterPasses('Home', null), isTrue);
      expect(tagFilterPasses('Home', 'Home'), isTrue);
      expect(tagFilterPasses('Home', 'Trip'), isFalse);
      expect(tagFilterPasses(null, 'Trip'), isFalse);
    });
  });

  group('format settings', () {
    test('no-decimals flag is honoured by inr/inrCompact', () {
      KanakkuTheme.noDecimals = false;
      expect(KanakkuTheme.inr(1234.5), '₹1,234.50');
      KanakkuTheme.noDecimals = true;
      expect(KanakkuTheme.inr(1234.5), '₹1,235');
      KanakkuTheme.noDecimals = false;
    });

    test('time-of-day honours the 12h/24h flag', () {
      KanakkuTheme.hour24 = false;
      expect(KanakkuTheme.fmtTimeOfDay(21, 0), '9:00 PM');
      expect(KanakkuTheme.fmtTimeOfDay(0, 5), '12:05 AM');
      KanakkuTheme.hour24 = true;
      expect(KanakkuTheme.fmtTimeOfDay(21, 0), '21:00');
      KanakkuTheme.hour24 = false;
    });
  });

  testWidgets('dark theme smoke: app builds and renders in dark mode', (
    tester,
  ) async {
    KanakkuTheme.applyAppearance(true);
    addTearDown(() => KanakkuTheme.applyAppearance(false));
    await tester.pumpWidget(
      MaterialApp(
        theme: KanakkuTheme.light(),
        darkTheme: KanakkuTheme.dark(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
          body: Card(
            child: Text(
              'Dark Kanakku ${KanakkuTheme.inr(1234)}',
              style: KanakkuTheme.serif(size: 18),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Dark Kanakku'), findsOneWidget);
    final ctx = tester.element(find.textContaining('Dark Kanakku'));
    expect(Theme.of(ctx).brightness, Brightness.dark);
    expect(KanakkuTheme.card, const Color(0xFF1D2A24));
  });

  testWidgets('Add sheet pre-selects the default payment mode from settings', (
    tester,
  ) async {
    const channel = MethodChannel('in.kanakku/capture');
    var savedManual = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'hasSmsPermission':
            case 'isNotificationAccessEnabled':
            case 'pinIsSet':
              return false;
            case 'getMessages':
              return <Object?>[];
            case 'getSettings':
              return encodeSettings(
                const KanakkuSettings(defaultPaymentMode: 'UPI'),
              );
            case 'getCategories':
              return '{}';
            case 'getManual':
            case 'getRemoved':
            case 'getSplits':
            case 'getStatement':
              return '[]';
            case 'getBudgets':
              return '{}';
            case 'setManual':
              savedManual = (call.arguments as Map)['json'] as String;
              return true;
            default:
              return true;
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(const KanakkuApp());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+  Add transaction'));
    await tester.pumpAndSettle();

    // The UPI chip (from settings) is the selected payment mode.
    final upiChip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'UPI'),
    );
    expect(upiChip.selected, isTrue);
    final cashChip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Cash'),
    );
    expect(cashChip.selected, isFalse);

    // Save an expense: mode + tag persist into the manual store.
    await tester.enterText(find.byType(TextField).first, '250');
    await tester.enterText(
      find.widgetWithText(TextField, 'Tag (optional)'),
      'Home',
    );
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(savedManual, contains('"mode":"UPI"'));
    expect(savedManual, contains('"tag":"Home"'));
  });
}
