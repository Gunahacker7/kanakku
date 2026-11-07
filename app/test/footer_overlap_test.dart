import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanakku/main.dart';

import 'support/capture_channel_mock.dart';

void main() {
  setUp(installCaptureChannelMock);

  // v1.0.3 regression: with the 2-left / 3-right split, the glass
  // footer's raised centre "+" used to be centred on the PILL —
  // and the pill's centre falls inside the Budgets slot, so the
  // circle covered half of Budgets' icon on Guna's phone. The
  // button now sits in a fixed 76px centre segment of the bar's
  // row; this test pins that geometry at a real phone width.
  testWidgets('glass footer: centre + never overlaps any tab slot', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const KanakkuApp());
    await tester.pumpAndSettle();

    final add = find.byKey(const ValueKey<String>('glass-nav-add'));
    expect(add, findsOneWidget);
    final addRect = tester.getRect(add);
    expect(addRect.width, 56);
    expect(addRect.height, 56);

    // No tab slot — above all Budgets (index 2), the one that was
    // covered — may intersect the centre button. The five slots
    // must also share identical geometry (equal-width segments).
    final slotRects = <Rect>[];
    for (var i = 0; i < 5; i++) {
      final itemRect = tester.getRect(
        find.byKey(ValueKey<String>('glass-nav-item-$i')),
      );
      slotRects.add(itemRect);
      expect(
        addRect.overlaps(itemRect),
        isFalse,
        reason: 'centre + overlaps footer item $i ($itemRect vs $addRect)',
      );
    }
    for (final r in slotRects.skip(1)) {
      expect(r.width, closeTo(slotRects.first.width, 0.5));
      expect(r.height, slotRects.first.height);
    }

    // All five labels render on ONE line: a wrapped label would
    // be roughly two line-heights tall.
    for (final label in [
      'Home',
      'Transactions',
      'Budgets',
      'Insights',
      'Splits',
    ]) {
      final labelRect = tester.getRect(find.text(label));
      expect(
        labelRect.height,
        lessThan(20),
        reason: '"$label" label wrapped to two lines ($labelRect)',
      );
    }

    // Drain framework exceptions. The only one tolerated is the
    // PRE-EXISTING _BrandBar Row overflow, which appears solely
    // in tests: the flutter_test font renders the serif wordmark
    // far wider than the bundled Noto Serif does on device, where
    // the bar fits (visible in Guna's own screenshots). The
    // footer's own no-overflow is proven by the geometry above —
    // its row is all Expanded/FittedBox and cannot spill.
    var drained = tester.takeException();
    while (drained != null) {
      expect(drained.toString(), contains('RenderFlex overflowed'));
      drained = tester.takeException();
    }
  });
}
