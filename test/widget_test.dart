import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nihongo_trainer/main.dart';
import 'package:nihongo_trainer/screens/home_screen.dart';

void main() {
  testWidgets(
    'App boots past the splash screen onto Home without throwing',
    (WidgetTester tester) async {
      await tester.pumpWidget(const NihongoTrainerApp());

      // The app's first frame is a branded splash screen while bundled JSON
      // and saved settings load (see main.dart's _AppLoader). Its spinner is
      // an indeterminate CircularProgressIndicator, which schedules another
      // frame forever while it's on screen -- so this deliberately pumps a
      // bounded number of fixed steps rather than calling pumpAndSettle,
      // which would time out waiting for an animation that never finishes
      // on its own.
      for (var i = 0;
          i < 20 && find.byType(HomeScreen).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(tester.takeException(), isNull);
      expect(find.byType(HomeScreen), findsOneWidget, reason:
          'Expected the loader to reach HomeScreen once app data finished '
          'loading.');
      expect(find.text('Nihongo Trainer'), findsOneWidget);
    },
  );
}
