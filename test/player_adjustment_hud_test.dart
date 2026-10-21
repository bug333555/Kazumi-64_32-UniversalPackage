import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/player_adjustment_hud.dart';

Future<void> pumpHud(WidgetTester tester, Widget hud) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: hud)),
    ),
  );
  await tester.pumpAndSettle();
}

void expectLightweightHud() {
  expect(find.byType(Slider), findsNothing);
  expect(find.byType(AnimatedOpacity), findsNothing);
  expect(find.byType(AnimatedSlide), findsNothing);
  expect(find.byType(AnimatedScale), findsNothing);
  expect(find.byType(AnimatedContainer), findsNothing);
  expect(find.byType(AnimatedSwitcher), findsNothing);
  expect(find.byType(BackdropFilter), findsNothing);
  final hud = find.byWidgetPredicate(
    (widget) =>
        widget is Container &&
        widget.decoration is BoxDecoration &&
        (widget.decoration! as BoxDecoration).color == Colors.black54,
  );
  expect(hud, findsOneWidget);
  final container = hud.evaluate().single.widget as Container;
  expect((container.decoration! as BoxDecoration).boxShadow, isNull);
}

void main() {
  test('HUD source contains no animation or custom-paint machinery', () {
    final source = File(
      'lib/pages/player/player_adjustment_hud.dart',
    ).readAsStringSync();
    for (final forbidden in <String>[
      'StatefulWidget',
      'Animated',
      'AnimationController',
      'Tween',
      'Ticker',
      'BackdropFilter',
      'ImageFilter',
      'BoxShadow',
      'CustomPainter',
      'Slider(',
      'Timer(',
      'addPostFrameCallback',
    ]) {
      expect(source.contains(forbidden), isFalse, reason: forbidden);
    }
  });

  testWidgets('volume uses the legacy icon and plain percentage', (
    tester,
  ) async {
    await pumpHud(
      tester,
      const PlayerAdjustmentHud(
        visible: true,
        type: PlayerAdjustmentHudType.volume,
        value: 53,
      ),
    );
    expect(find.byIcon(Icons.volume_down), findsOneWidget);
    expect(find.text(' 53%'), findsOneWidget);
    expectLightweightHud();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('brightness clamps to a safe legacy percentage', (tester) async {
    await pumpHud(
      tester,
      const PlayerAdjustmentHud(
        visible: true,
        type: PlayerAdjustmentHudType.brightness,
        value: 1.5,
      ),
    );
    expect(find.text(' 100 %'), findsOneWidget);
    expectLightweightHud();
    await pumpHud(
      tester,
      const PlayerAdjustmentHud(
        visible: true,
        type: PlayerAdjustmentHudType.brightness,
        value: -1,
      ),
    );
    expect(find.text(' 0 %'), findsOneWidget);
  });

  testWidgets('seek displays forward and backward text without progress art', (
    tester,
  ) async {
    await pumpHud(
      tester,
      const PlayerSeekHud(
        visible: true,
        currentPosition: Duration(seconds: 15),
        playerPosition: Duration(seconds: 10),
        duration: Duration(minutes: 20),
        direction: 1,
      ),
    );
    expect(find.text('快进 5 秒'), findsOneWidget);
    expectLightweightHud();
    await pumpHud(
      tester,
      const PlayerSeekHud(
        visible: true,
        currentPosition: Duration(seconds: 5),
        playerPosition: Duration(seconds: 10),
        duration: Duration(minutes: 20),
        direction: -1,
      ),
    );
    expect(find.text('快退 5 秒'), findsOneWidget);
  });

  testWidgets('seek cancellation keeps the new controller input', (
    tester,
  ) async {
    await pumpHud(
      tester,
      const PlayerSeekHud(
        visible: true,
        currentPosition: Duration(seconds: 20),
        playerPosition: Duration(seconds: 10),
        duration: Duration(minutes: 20),
        direction: 1,
        cancelPending: true,
      ),
    );
    expect(find.text('取消快进 / 快退'), findsOneWidget);
    expectLightweightHud();
  });

  testWidgets('speed keeps the legacy lightweight feedback', (tester) async {
    await pumpHud(tester, const PlayerSpeedHud(visible: true, speed: 2));
    expect(find.byIcon(Icons.fast_forward), findsOneWidget);
    expect(find.text(' 倍速播放'), findsOneWidget);
    expectLightweightHud();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('all hidden HUDs have no icon, text, animation or visible size', (
    tester,
  ) async {
    for (final hud in <Widget>[
      const PlayerAdjustmentHud(
        visible: false,
        type: PlayerAdjustmentHudType.volume,
        value: 53,
      ),
      const PlayerSeekHud(
        visible: false,
        currentPosition: Duration(seconds: 20),
        playerPosition: Duration(seconds: 10),
        duration: Duration(minutes: 20),
        direction: 1,
      ),
      const PlayerSpeedHud(visible: false, speed: 2),
    ]) {
      await pumpHud(tester, hud);
      expect(tester.getSize(find.byType(hud.runtimeType)), Size.zero);
      expect(find.byType(Text), findsNothing);
      expect(find.byType(Icon), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    }
  });
}
