import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dlna_dart/xmlParser.dart';
import 'package:xml/xml.dart';

enum DlnaTransportState {
  playing,
  transitioning,
  paused,
  stopped,
  noMedia,
  unknown,
}

abstract class DlnaTransport {
  Future<void> setLegacyUri(String url, {String title = 'Kazumi'});

  Future<void> setUriWithMetadata(
    String url, {
    String title = 'Kazumi',
    String? mimeType,
  });

  Future<void> play();

  Future<DlnaTransportState> getTransportState();
}

class DlnaSoapException implements Exception {
  const DlnaSoapException({
    required this.action,
    required this.uri,
    required this.statusCode,
    this.errorCode,
    this.description,
  });

  final String action;
  final Uri uri;
  final int statusCode;
  final int? errorCode;
  final String? description;

  @override
  String toString() {
    final details = [
      if (errorCode != null) 'UPnP $errorCode',
      if (description != null && description!.isNotEmpty) description!,
    ].join(': ');
    return 'DLNA $action failed with HTTP $statusCode'
        '${details.isEmpty ? '' : ' ($details)'}';
  }
}

class DlnaTransportClient implements DlnaTransport {
  DlnaTransportClient(
    this.info, {
    this.timeout = const Duration(seconds: 15),
  })  : serviceType = _serviceTypeFor(info),
        controlUri = controlUriFor(info) ??
            (throw ArgumentError('Device has no usable AVTransport service'));

  final DeviceInfo info;
  final Duration timeout;
  final String serviceType;
  final Uri controlUri;

  static bool hasAvTransportService(DeviceInfo info) =>
      _findAvTransportService(info) != null;

  static Uri? controlUriFor(DeviceInfo info) {
    final service = _findAvTransportService(info);
    final controlPath = service?['controlURL']?.toString().trim();
    final base = Uri.tryParse(info.URLBase.trim());
    if (controlPath == null || controlPath.isEmpty || base == null) {
      return null;
    }
    if (controlPath.startsWith('/')) {
      return base.resolve(controlPath);
    }
    final directoryBase = base.path.endsWith('/')
        ? base
        : base.replace(path: '${base.path}/', query: null, fragment: null);
    return directoryBase.resolve(controlPath);
  }

  static Map<dynamic, dynamic>? _findAvTransportService(DeviceInfo info) {
    for (final service in info.serviceList) {
      if (service is! Map) {
        continue;
      }
      final serviceId = service['serviceId']?.toString() ?? '';
      final serviceType = service['serviceType']?.toString() ?? '';
      if (serviceId.contains('AVTransport') ||
          serviceType.contains('AVTransport')) {
        return service;
      }
    }
    return null;
  }

  static String _serviceTypeFor(DeviceInfo info) {
    final value =
        _findAvTransportService(info)?['serviceType']?.toString().trim();
    if (value != null && value.contains('AVTransport')) {
      return value;
    }
    return 'urn:schemas-upnp-org:service:AVTransport:1';
  }

  @override
  Future<void> setLegacyUri(String url, {String title = 'Kazumi'}) async {
    await _post(
      'SetAVTransportURI',
      _buildSetUriEnvelope(
        url,
        _buildLegacyMetadata(url),
        serviceType: serviceType,
      ),
    );
  }

  @override
  Future<void> setUriWithMetadata(
    String url, {
    String title = 'Kazumi',
    String? mimeType,
  }) async {
    await _post(
      'SetAVTransportURI',
      _buildSetUriEnvelope(
        url,
        _buildMetadata(
          url,
          title: title,
          mimeType: mimeType ?? inferDlnaMimeType(url),
        ),
        serviceType: serviceType,
      ),
    );
  }

  @override
  Future<void> play() async {
    await _post(
      'Play',
      _buildActionEnvelope(
        'Play',
        serviceType: serviceType,
        fields: {'Speed': '1'},
      ),
    );
  }

  @override
  Future<DlnaTransportState> getTransportState() async {
    final body = await _post(
      'GetTransportInfo',
      _buildActionEnvelope(
        'GetTransportInfo',
        serviceType: serviceType,
      ),
    );
    final state = _xmlValue(body, 'CurrentTransportState').toUpperCase();
    return switch (state) {
      'PLAYING' => DlnaTransportState.playing,
      'TRANSITIONING' => DlnaTransportState.transitioning,
      'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => DlnaTransportState.paused,
      'STOPPED' => DlnaTransportState.stopped,
      'NO_MEDIA_PRESENT' => DlnaTransportState.noMedia,
      _ => DlnaTransportState.unknown,
    };
  }

  Future<String> _post(String action, String body) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(controlUri).timeout(timeout);
      request.headers.set(
        'SOAPAction',
        '"$serviceType#$action"',
      );
      request.headers.contentType = ContentType(
        'text',
        'xml',
        charset: 'utf-8',
      );
      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(timeout);
      final responseBody =
          await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DlnaSoapException(
          action: action,
          uri: controlUri,
          statusCode: response.statusCode,
          errorCode: int.tryParse(_xmlValue(responseBody, 'errorCode')),
          description: _xmlValue(responseBody, 'errorDescription'),
        );
      }
      return responseBody;
    } finally {
      client.close(force: true);
    }
  }

  static String _buildSetUriEnvelope(
    String url,
    String metadata, {
    required String serviceType,
  }) {
    return _buildActionEnvelope(
      'SetAVTransportURI',
      serviceType: serviceType,
      fields: {
        'CurrentURI': url,
        'CurrentURIMetaData': metadata,
      },
    );
  }

  static String _buildActionEnvelope(
    String action, {
    required String serviceType,
    Map<String, String> fields = const {},
  }) {
    const soapNamespace = 'http://schemas.xmlsoap.org/soap/envelope/';
    final builder = XmlBuilder();
    builder.processing(
      'xml',
      'version="1.0" encoding="utf-8" standalone="yes"',
    );
    builder.element(
      'Envelope',
      namespace: soapNamespace,
      namespaces: const {soapNamespace: 's'},
      nest: () {
        builder.attribute(
          'encodingStyle',
          'http://schemas.xmlsoap.org/soap/encoding/',
          namespace: soapNamespace,
        );
        builder.element('Body', namespace: soapNamespace, nest: () {
          builder.element(
            action,
            namespace: serviceType,
            namespaces: {serviceType: 'u'},
            nest: () {
              builder.element('InstanceID', nest: '0');
              for (final field in fields.entries) {
                builder.element(field.key, nest: field.value);
              }
            },
          );
        });
      },
    );
    return builder.buildDocument().toXmlString();
  }

  static String _buildLegacyMetadata(String title) {
    final builder = XmlBuilder();
    builder.element(
      'DIDL-Lite',
      namespace: _didlNamespace,
      namespaces: _didlNamespaces,
      nest: () {
        builder.element(
          'item',
          namespace: _didlNamespace,
          attributes: {'id': 'false', 'parentID': '1', 'restricted': '0'},
          nest: () {
            builder.element('title', namespace: _dcNamespace, nest: title);
            builder.element(
              'creator',
              namespace: _dcNamespace,
              nest: 'unkown',
            );
            builder.element(
              'class',
              namespace: _upnpNamespace,
              nest: 'object.item.videoItem',
            );
            builder.element(
              'res',
              namespace: _didlNamespace,
              attributes: {'resolution': '4'},
              isSelfClosing: false,
            );
          },
        );
      },
    );
    return builder.buildFragment().children.single.toXmlString();
  }

  static String _buildMetadata(
    String url, {
    required String title,
    required String mimeType,
  }) {
    final builder = XmlBuilder();
    builder.element(
      'DIDL-Lite',
      namespace: _didlNamespace,
      namespaces: _didlNamespaces,
      nest: () {
        builder.element(
          'item',
          namespace: _didlNamespace,
          attributes: {'id': '0', 'parentID': '0', 'restricted': '1'},
          nest: () {
            builder.element(
              'title',
              namespace: _dcNamespace,
              nest: title,
            );
            builder.element(
              'class',
              namespace: _upnpNamespace,
              nest: 'object.item.videoItem',
            );
            builder.element(
              'res',
              namespace: _didlNamespace,
              attributes: {'protocolInfo': 'http-get:*:$mimeType:*'},
              nest: url,
            );
          },
        );
      },
    );
    return builder.buildFragment().children.single.toXmlString();
  }

  static const _didlNamespace =
      'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/';
  static const _upnpNamespace =
      'urn:schemas-upnp-org:metadata-1-0/upnp/';
  static const _dcNamespace = 'http://purl.org/dc/elements/1.1/';
  static const _secNamespace = 'http://www.sec.co.kr/';
  static const _didlNamespaces = <String, String?>{
    _didlNamespace: null,
    _upnpNamespace: 'upnp',
    _dcNamespace: 'dc',
    _secNamespace: 'sec',
  };

  static String _xmlValue(String body, String name) {
    if (body.isEmpty) {
      return '';
    }
    try {
      final elements = XmlDocument.parse(body).findAllElements(name);
      if (elements.isNotEmpty) {
        return elements.first.innerText.trim();
      }
    } catch (_) {}
    final match = RegExp(
      '<(?:[^:>]+:)?$name[^>]*>(.*?)</(?:[^:>]+:)?$name>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(body);
    return match?.group(1)?.trim() ?? '';
  }
}

String inferDlnaMimeType(String url) {
  final lower = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  if (lower.endsWith('.m3u8')) {
    return 'application/vnd.apple.mpegurl';
  }
  if (lower.endsWith('.ts')) {
    return 'video/vnd.dlna.mpeg-tts';
  }
  if (lower.endsWith('.mkv')) {
    return 'video/x-matroska';
  }
  if (lower.endsWith('.webm')) {
    return 'video/webm';
  }
  if (lower.endsWith('.flv')) {
    return 'video/x-flv';
  }
  return 'video/mp4';
}
