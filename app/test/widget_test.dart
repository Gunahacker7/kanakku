import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/main.dart';

import 'support/capture_channel_mock.dart';

void main() {
  setUp(installCaptureChannelMock);

  testWidgets('Kanakku home shows the v1.2 overview', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const KanakkuApp());
    await tester.pumpAndSettle();

    // v1.2 greeting header: the default profile name, uppercased
    // (Settings → Profile name drives it).
    expect(find.text('GUNA'), findsOneWidget);
    // Stat pair (period figures are date-dependent; labels are not).
    expect(find.text('Spent this month'), findsOneWidget);
    expect(find.text('Budget left'), findsOneWidget);
    // Monthly Spending chart card under the stats.
    await tester.scrollUntilVisible(find.text('Monthly Spending'), 250);
    expect(find.text('Monthly Spending'), findsOneWidget);
    // OTP message must NOT appear as a transaction
    expect(find.text('Money in'), findsNothing);
    // Three-tab bottom nav (v1.2 shell).
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Calendar'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    // Capture chips live in the Today card, below the chart
    await tester.scrollUntilVisible(find.text('SMS off — tap'), 250);
    expect(find.text('SMS off — tap'), findsOneWidget);

    // Budget check-in card further down the Home list
    await tester.scrollUntilVisible(find.text('Budget check-in'), 250);
    expect(find.text('Budget check-in'), findsOneWidget);
    // Statement upload card sits below the check-in card
    await tester.scrollUntilVisible(find.text('Upload bank statement'), 250);
    expect(find.text('Upload bank statement'), findsWidgets);
  });
}
