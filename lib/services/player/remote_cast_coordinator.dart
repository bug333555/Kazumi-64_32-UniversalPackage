import 'dart:async';

import 'package:dlna_dart/xmlParser.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/dlna_transport_client.dart';
import 'package:kazumi/services/player/remote_stream_proxy.dart';

enum RemoteCastStrategy {
  legacyDirect,
  metadataDirect,
  headerProxy,
}

class RemoteCastResult {
  const RemoteCastResult({
    required this.strategy,
    required this.verifiedPlaying,
  });

  final RemoteCastStrategy strategy;
  final bool verifiedPlaying;
}

class RemoteCastException implements Exception {
  const RemoteCastException(this.failures);

  final Map<RemoteCastStrategy, Object> failures;

  @override
  String toString() => failures.entries
      .map((entry) => '${entry.key.name}: ${entry.value}')
      .join('; ');
}

typedef DlnaTransportFactory = DlnaTransport Function(DeviceInfo info);
typedef ProxyUrlPreparer = Future<String> Function(
  String sourceUrl,
  Map<String, String> headers,
  String rendererBaseUrl,
);

class RemoteCastCoordinator {
  RemoteCastCoordinator({
    DlnaTransportFactory? transportFactory,
    ProxyUrlPreparer? proxyPreparer,
    this.playDelay = const Duration(milliseconds: 450),
    this.verifyDelay = const Duration(milliseconds: 500),
    this.verifyAttempts = 3,
  })  : _transportFactory =
            transportFactory ?? ((info) => DlnaTransportClient(info)),
        _proxyPreparer = proxyPreparer ??
            ((sourceUrl, headers, rendererBaseUrl) =>
                RemoteStreamProxy.instance.prepare(
                  sourceUrl,
                  headers: headers,
                  rendererBaseUrl: rendererBaseUrl,
                ));

  final DlnaTransportFactory _transportFactory;
  final ProxyUrlPreparer _proxyPreparer;
  final Duration playDelay;
  final Duration verifyDelay;
  final int verifyAttempts;

  Future<RemoteCastResult> cast(
    DeviceInfo info,
    String sourceUrl, {
    required Map<String, String> httpHeaders,
    String title = 'Kazumi',
    Iterable<RemoteCastStrategy>? strategies,
  }) async {
    final failures = <RemoteCastStrategy, Object>{};
    for (final strategy in strategies ?? RemoteCastStrategy.values) {
      try {
        final transport = _transportFactory(info);
        final targetUrl = strategy == RemoteCastStrategy.headerProxy
            ? await _proxyPreparer(sourceUrl, httpHeaders, info.URLBase)
            : sourceUrl;
        if (strategy == RemoteCastStrategy.legacyDirect) {
          await transport.setLegacyUri(targetUrl, title: title);
        } else {
          await transport.setUriWithMetadata(
            targetUrl,
            title: title,
            mimeType: inferDlnaMimeType(targetUrl),
          );
        }
        await Future<void>.delayed(playDelay);
        await _playWithRetry(transport);
        final verification = await _verifyPlayback(transport);
        if (verification == _PlaybackVerification.rejected) {
          throw StateError('Renderer remained stopped after Play');
        }
        return RemoteCastResult(
          strategy: strategy,
          verifiedPlaying: verification == _PlaybackVerification.playing,
        );
      } catch (error, stackTrace) {
        failures[strategy] = error;
        KazumiLogger().w(
          'RemotePlay: ${strategy.name} failed for ${info.friendlyName}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    throw RemoteCastException(failures);
  }

  Future<void> _playWithRetry(DlnaTransport transport) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await transport.play();
        return;
      } catch (error) {
        lastError = error;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
      }
    }
    throw lastError ?? StateError('DLNA Play failed');
  }

  Future<_PlaybackVerification> _verifyPlayback(
    DlnaTransport transport,
  ) async {
    var sawTerminalState = false;
    for (var attempt = 0; attempt < verifyAttempts; attempt++) {
      await Future<void>.delayed(verifyDelay);
      try {
        final state = await transport.getTransportState();
        switch (state) {
          case DlnaTransportState.playing:
            return _PlaybackVerification.playing;
          case DlnaTransportState.transitioning:
            continue;
          case DlnaTransportState.stopped:
          case DlnaTransportState.noMedia:
            sawTerminalState = true;
            continue;
          case DlnaTransportState.paused:
          case DlnaTransportState.unknown:
            return _PlaybackVerification.acceptedUnverified;
        }
      } catch (_) {
        return _PlaybackVerification.acceptedUnverified;
      }
    }
    return sawTerminalState
        ? _PlaybackVerification.rejected
        : _PlaybackVerification.acceptedUnverified;
  }
}

enum _PlaybackVerification {
  playing,
  acceptedUnverified,
  rejected,
}
