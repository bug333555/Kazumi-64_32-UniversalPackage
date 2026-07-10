import 'dart:convert';
import 'dart:io';

import 'package:dlna_dart/xmlParser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/dlna_transport_client.dart';
import 'package:xml/xml.dart';

void main() {
  test('filters devices without AVTransport safely', () {
    final basic = DeviceInfo(
      'http://192.168.1.20:80/',
      'urn:schemas-upnp-org:device:Basic:1',
      'Basic device',
      const [],
    );

    expect(DlnaTransportClient.hasAvTransportService(basic), isFalse);
    expect(DlnaTransportClient.controlUriFor(basic), isNull);
  });

  test('resolves relative and root AVTransport control URLs', () {
    final relative = _device(
      'http://192.168.1.10:1400/device/',
      'upnp/control/AVTransport',
    );
    final rooted = _device(
      'http://192.168.1.10:1400/device/',
      '/upnp/control/AVTransport',
    );

    expect(
      DlnaTransportClient.controlUriFor(relative)!.toString(),
      'http://192.168.1.10:1400/device/upnp/control/AVTransport',
    );
    expect(
      DlnaTransportClient.controlUriFor(rooted)!.toString(),
      'http://192.168.1.10:1400/upnp/control/AVTransport',
    );
  });

  test('sends a normalized DIDL resource without double escaping', () async {
    late String requestBody;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requestBody = await _readRequestBody(request);
      request.response.write(_soapResponse('SetAVTransportURIResponse'));
      await request.response.close();
    });

    final client = DlnaTransportClient(
      _device(
        'http://${server.address.host}:${server.port}/',
        '/control',
      ),
    );
    await client.setUriWithMetadata(
      'https://video.example/movie.mp4?a=1&b=2',
      title: 'A & B',
    );

    final soap = XmlDocument.parse(requestBody);
    expect(
      soap.findAllElements('CurrentURI').single.innerText,
      'https://video.example/movie.mp4?a=1&b=2',
    );
    final metadata = soap.findAllElements('CurrentURIMetaData').single.innerText;
    final didl = _parseMetadata(metadata);
    final resource = _element(didl, 'res');
    expect(resource.innerText, 'https://video.example/movie.mp4?a=1&b=2');
    expect(resource.getAttribute('protocolInfo'), 'http-get:*:video/mp4:*');
    expect(_element(didl, 'title').innerText, 'A & B');
  });

  test('legacy direct metadata matches the known 2.1.1 setUrl shape', () async {
    late String requestBody;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requestBody = await _readRequestBody(request);
      request.response.write(_soapResponse('SetAVTransportURIResponse'));
      await request.response.close();
    });

    final client = DlnaTransportClient(
      _device(
        'http://${server.address.host}:${server.port}/',
        '/control',
      ),
    );
    const videoUrl = 'https://video.example/legacy.mp4';
    await client.setLegacyUri(videoUrl, title: 'Ignored title');

    final soap = XmlDocument.parse(requestBody);
    final metadata = soap.findAllElements('CurrentURIMetaData').single.innerText;
    final didl = _parseMetadata(metadata);
    expect(_element(didl, 'title').innerText, videoUrl);
    expect(_element(didl, 'creator').innerText, 'unkown');
    final resource = _element(didl, 'res');
    expect(resource.innerText, isEmpty);
    expect(resource.getAttribute('resolution'), '4');
  });

  test('parses UPnP 501 errors from SetAVTransportURI', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('''
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body><s:Fault><detail><UPnPError>
    <errorCode>501</errorCode>
    <errorDescription>Action SetAVTransportURI failed</errorDescription>
  </UPnPError></detail></s:Fault></s:Body>
</s:Envelope>
''');
      await request.response.close();
    });

    final client = DlnaTransportClient(
      _device(
        'http://${server.address.host}:${server.port}/',
        '/control',
      ),
    );

    await expectLater(
      client.setLegacyUri('https://video.example/movie.mp4'),
      throwsA(
        isA<DlnaSoapException>()
            .having((error) => error.errorCode, 'errorCode', 501)
            .having(
              (error) => error.description,
              'description',
              'Action SetAVTransportURI failed',
            ),
      ),
    );
  });

  test('uses the AVTransport version advertised by the renderer', () async {
    late String soapAction;
    late String requestBody;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      soapAction = request.headers.value('soapaction') ?? '';
      requestBody = await _readRequestBody(request);
      request.response.write(_soapResponse('SetAVTransportURIResponse'));
      await request.response.close();
    });

    final client = DlnaTransportClient(
      _device(
        'http://${server.address.host}:${server.port}/',
        '/control',
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:2',
      ),
    );
    await client.setUriWithMetadata('https://video.example/movie.mp4');

    expect(soapAction, contains('AVTransport:2#SetAVTransportURI'));
    expect(
      requestBody,
      contains('xmlns:u="urn:schemas-upnp-org:service:AVTransport:2"'),
    );
  });
}

DeviceInfo _device(
  String baseUrl,
  String controlUrl, {
  String serviceType = 'urn:schemas-upnp-org:service:AVTransport:1',
}) {
  return DeviceInfo(
    baseUrl,
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'Test renderer',
    [
      {
        'serviceType': serviceType,
        'serviceId': 'urn:upnp-org:serviceId:AVTransport',
        'controlURL': controlUrl,
      },
    ],
  );
}

String _soapResponse(String action) => '''
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body><u:$action
    xmlns:u="urn:schemas-upnp-org:service:AVTransport:1" />
  </s:Body>
</s:Envelope>
''';

Future<String> _readRequestBody(HttpRequest request) async {
  final bytes = await request.fold<List<int>>(
    <int>[],
    (buffer, chunk) => buffer..addAll(chunk),
  );
  return utf8.decode(bytes);
}

XmlDocument _parseMetadata(String metadata) {
  try {
    return XmlDocument.parse(metadata);
  } catch (error) {
    fail('Invalid DIDL metadata: $metadata\n$error');
  }
}

XmlElement _element(XmlDocument document, String localName) {
  return document.descendants
      .whereType<XmlElement>()
      .singleWhere((element) => element.name.local == localName);
}
