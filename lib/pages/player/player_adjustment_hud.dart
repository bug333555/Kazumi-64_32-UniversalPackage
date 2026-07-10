import 'package:flutter/material.dart';

enum PlayerAdjustmentHudType {
  brightness,
  volume,
}

class PlayerAdjustmentHud extends StatelessWidget {
  const PlayerAdjustmentHud({
    super.key,
    required this.visible,
    required this.type,
    required this.value,
    this.disableAnimations = false,
  });

  final bool visible;
  final PlayerAdjustmentHudType type;
  final double value;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return Container();
    }

    final bool isVolume = type == PlayerAdjustmentHudType.volume;
    final IconData icon = isVolume ? Icons.volume_down : Icons.brightness_7;
    final String text = isVolume
        ? ' ${value.toInt()}%'
        : ' ${(value.clamp(0.0, 1.0) * 100).toInt()} %';

    return _LegacyPlayerHud(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, color: Colors.white),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class PlayerSeekHud extends StatelessWidget {
  const PlayerSeekHud({
    super.key,
    required this.visible,
    required this.currentPosition,
    required this.playerPosition,
    required this.duration,
    required this.direction,
    this.disableAnimations = false,
  });

  final bool visible;
  final Duration currentPosition;
  final Duration playerPosition;
  final Duration duration;
  final int direction;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return Container();
    }

    final bool isForward = currentPosition.compareTo(playerPosition) > 0;
    final int seconds = isForward
        ? currentPosition.inSeconds - playerPosition.inSeconds
        : playerPosition.inSeconds - currentPosition.inSeconds;

    return _LegacyPlayerHud(
      child: Text(
        isForward ? '快进 $seconds 秒' : '快退 $seconds 秒',
        style: const TextStyle(
          color: Colors.white,
        ),
      ),
    );
  }
}

class PlayerSpeedHud extends StatelessWidget {
  const PlayerSpeedHud({
    super.key,
    required this.visible,
    required this.speed,
    this.disableAnimations = false,
  });

  final bool visible;
  final double speed;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return Container();
    }

    return const _LegacyPlayerHud(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.fast_forward, color: Colors.white),
          Text(
            ' 倍速播放',
            style: TextStyle(
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _LegacyPlayerHud extends StatelessWidget {
  const _LegacyPlayerHud({
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(8.0),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8.0),
          ),
          child: child,
        ),
      ],
    );
  }
}
