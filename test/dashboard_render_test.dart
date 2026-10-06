import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rehab_monitor/main.dart';

void main() {
  testWidgets('truthful exercise home renders with bundled fonts', (
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
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('Squat'), findsOneWidget);
    expect(find.text('Sit-to-stand'), findsOneWidget);
    expect(find.text('78%'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
