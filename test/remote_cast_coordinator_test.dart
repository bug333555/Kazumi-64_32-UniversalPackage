import 'package:dlna_dart/xmlParser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/dlna_transport_client.dart';
import 'package:kazumi/services/player/remote_cast_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('falls back from legacy direct to normalized metadata on 501', () async {
    final transport = _FakeTransport(
      legacyError: DlnaSoapException(
        action: 'SetAVTransportURI',
        uri: Uri.parse('http://127.0.0.1/control'),
        statusCode: 500,
        errorCode: 501,
      ),
      states: [DlnaTransportState.playing],
    );
    final coordinator = RemoteCastCoordinator(
      transportFactory: (_) => transport,
      playDelay: Duration.zero,
      verifyDelay: Duration.zero,
    );

    final result = await coordinator.cast(
      _device(),
      'https://video.example/movie.mp4',
      httpHeaders: const {'user-agent': 'KazumiTest'},
    );

    expect(result.strategy, RemoteCastStrategy.metadataDirect);
    expect(result.verifiedPlaying, isTrue);
    expect(transport.legacyCalls, 1);
    expect(transport.metadataCalls, 1);
  });

  test('uses the header proxy only after direct strategies remain stopped',
      () async {
    final transports = <_FakeTransport>[
      _FakeTransport(states: const [
        DlnaTransportState.stopped,
        DlnaTransportState.stopped,
        DlnaTransportState.stopped,
      ]),
      _FakeTransport(states: const [
        DlnaTransportState.noMedia,
        DlnaTransportState.noMedia,
        DlnaTransportState.noMedia,
      ]),
      _FakeTransport(states: const [DlnaTransportState.playing]),
    ];
    var factoryIndex = 0;
    var proxyCalls = 0;
    final coordinator = RemoteCastCoordinator(
      transportFactory: (_) => transports[factoryIndex++],
      proxyPreparer: (sourceUrl, headers, rendererBaseUrl) async {
        proxyCalls++;
        expect(headers['cookie'], 'session=abc');
        return 'http://192.168.1.2:1234/stream/token/video.mp4';
      },
      playDelay: Duration.zero,
      verifyDelay: Duration.zero,
    );

    final result = await coordinator.cast(
      _device(),
      'https://video.example/protected',
      httpHeaders: const {'cookie': 'session=abc'},
    );

    expect(result.strategy, RemoteCastStrategy.headerProxy);
    expect(proxyCalls, 1);
    expect(transports.last.lastUrl, endsWith('/video.mp4'));
  });

  test('does not treat a transient transitioning state as confirmed playback',
      () async {
    final transports = <_FakeTransport>[
      _FakeTransport(states: const [
        DlnaTransportState.transitioning,
        DlnaTransportState.stopped,
        DlnaTransportState.stopped,
      ]),
      _FakeTransport(states: const [DlnaTransportState.playing]),
    ];
    var factoryIndex = 0;
    final coordinator = RemoteCastCoordinator(
      transportFactory: (_) => transports[factoryIndex++],
      playDelay: Duration.zero,
      verifyDelay: Duration.zero,
    );

    final result = await coordinator.cast(
      _device(),
      'https://video.example/movie.mp4',
      httpHeaders: const {'user-agent': 'KazumiTest'},
      strategies: const [
        RemoteCastStrategy.legacyDirect,
        RemoteCastStrategy.metadataDirect,
      ],
    );

    expect(result.strategy, RemoteCastStrategy.metadataDirect);
    expect(result.verifiedPlaying, isTrue);
  });
}

class _FakeTransport implements DlnaTransport {
  _FakeTransport({
    this.legacyError,
    List<DlnaTransportState> states = const [DlnaTransportState.unknown],
  }) : _states = List<DlnaTransportState>.from(states);

  final Object? legacyError;
  final List<DlnaTransportState> _states;
  int legacyCalls = 0;
  int metadataCalls = 0;
  String lastUrl = '';

  @override
  Future<DlnaTransportState> getTransportState() async {
    return _states.isEmpty ? DlnaTransportState.unknown : _states.removeAt(0);
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> setLegacyUri(String url, {String title = 'Kazumi'}) async {
    legacyCalls++;
    lastUrl = url;
    if (legacyError != null) {
      throw legacyError!;
    }
  }

  @override
  Future<void> setUriWithMetadata(
    String url, {
    String title = 'Kazumi',
    String? mimeType,
  }) async {
    metadataCalls++;
    lastUrl = url;
  }
}

DeviceInfo _device() => DeviceInfo(
      'http://192.168.1.10/',
      'urn:schemas-upnp-org:device:MediaRenderer:1',
      'Test renderer',
      [
        {
          'serviceType': 'urn:schemas-upnp-org:service:AVTransport:1',
          'serviceId': 'urn:upnp-org:serviceId:AVTransport',
          'controlURL': '/control',
        },
      ],
    );
