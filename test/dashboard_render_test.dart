import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/main.dart';

void main() {
  testWidgets('renders the real shader with bundled fonts on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await (FontLoader(
        'Manrope',
      )..addFont(rootBundle.load('assets/fonts/Manrope.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    await tester.pumpWidget(const RepaintBoundary(child: MyApp()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MyApp),
      matchesGoldenFile('goldens/dashboard-phone.png'),
    );
    await tester.scrollUntilVisible(
      find.text('Sample session · Sensors are not connected'),
      180,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MyApp),
      matchesGoldenFile('goldens/dashboard-phone-scrolled.png'),
    );
    tester.view.physicalSize = const Size(1024, 900);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1500));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MyApp),
      matchesGoldenFile('goldens/dashboard-wide.png'),
    );
  });
}
