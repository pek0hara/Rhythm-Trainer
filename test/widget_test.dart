import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rhythm_trainer/main.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MetronomeApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
