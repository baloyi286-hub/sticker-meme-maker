import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sticker_meme_maker/main.dart';

void main() {
  testWidgets('Shows meme editor', (tester) async {
    await tester.pumpWidget(const MemeApp());
    expect(find.text('Sticker Meme Maker'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
