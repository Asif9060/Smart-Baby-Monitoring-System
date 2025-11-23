// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:babymonitor/main.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Dashboard title renders', (WidgetTester tester) async {
    await tester.pumpWidget(
      BabyMonitorApp(overrideStream: Stream<DatabaseEvent>.empty()),
    );

    expect(find.text('Smart Baby Monitor'), findsOneWidget);
  });
}
