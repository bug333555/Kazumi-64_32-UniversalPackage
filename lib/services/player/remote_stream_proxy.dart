import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:kazumi/services/logging/logger.dart';

class RemoteStreamProxy {
  RemoteStreamProxy._();

  static final RemoteStreamProxy instance = RemoteStreamProxy._();

  static const _tokenLength = 18;
  static const _proxyPrefix = 'stream';
  static const _entryLifetime = Duration(hours: 6);

  final _entries = <String, _ProxyEntry>{};
  final _random = Random.secure();
  HttpServer? _server;
  String? _advertisedHost;

  Future<String> prepare(
    String sourceUrl, {
    required Map<String, String> headers,
    String? rendererBaseUrl,
  }) async {
    final sourceUri = Uri.tryParse(sourceUrl);
    if (sourceUri == null ||
        (sourceUri.scheme != 'http' && sourceUri.scheme != 'https')) {
      return sourceUrl;
    }

    await _ensureServer(rendererBaseUrl: rendererBaseUrl);
    _removeExpiredEntries();
    return _register(sourceUri, headers);
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _advertisedHost = null;
    _entries.clear();
    await server?.close(force: true);
  }

  Future<void> _ensureServer({String? rendererBaseUrl}) async {
    if (_server != null) {
      _advertisedHost = await _selectAdvertisedHost(rendererBaseUrl);
      return;
    }

    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: true);
    _advertisedHost = await _selectAdvertisedHost(rendererBaseUrl);
    _server!.listen(
      _handleRequest,
      onError: (Object error, StackTrace stackTrace) {
        KazumiLogger().w('RemoteStreamProxy: server error', error: error);
      },
      cancelOnError: false,
    );
    KazumiLogger()
        .i('RemoteStreamProxy: listening on $_advertisedHost:${_server!.port}');
  }

  String _register(Uri sourceUri, Map<String, String> headers) {
    final token = _newToken();
    _entries[token] = _ProxyEntry(
      sourceUri: sourceUri,
      headers: Map.unmodifiable(headers),
      createdAt: DateTime.now(),
    );
    return Uri(
      scheme: 'http',
      host: _advertisedHost,
      port: _server!.port,
      pathSegments: [_proxyPrefix, token],
    ).toString();
  }

  String _newToken() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    while (true) {
      final token = List.generate(
        _tokenLength,
        (_) => chars[_random.nextInt(chars.length)],
      ).join();
      if (!_entries.containsKey(token)) {
        return token;
      }
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length != 2 || segments.first != _proxyPrefix) {
        await _respondText(request.response, HttpStatus.notFound, 'Not found');
        return;
      }

      final entry = _entries[segments[1]];
      if (entry == null) {
        await _respondText(request.response, HttpStatus.notFound, 'Expired');
        return;
      }

      if (request.method != 'GET' && request.method != 'HEAD') {
        await _respondText(
          request.response,
          HttpStatus.methodNotAllowed,
          'Method not allowed',
        );
        return;
      }

      await _proxyEntry(request, entry);
    } catch (e, stackTrace) {
      KazumiLogger().e('RemoteStreamProxy: request failed',
          error: e, stackTrace: stackTrace);
      try {
        await _respondText(
          request.response,
          HttpStatus.internalServerError,
          'Proxy error',
        );
      } catch (_) {
        await request.response.close();
      }
    }
  }

  Future<void> _proxyEntry(HttpRequest request, _ProxyEntry entry) async {
    final client = HttpClient();
    try {
      final upstreamRequest = request.method == 'HEAD'
          ? await client.headUrl(entry.sourceUri)
          : await client.getUrl(entry.sourceUri);

      _applySourceHeaders(upstreamRequest, entry.headers);
      _forwardRequestHeader(request, upstreamRequest, HttpHeaders.rangeHeader);
      _forwardRequestHeader(request, upstreamRequest, HttpHeaders.acceptHeader);

      final upstreamResponse = await upstreamRequest.close();
      final isPlaylist = _isPlaylist(entry.sourceUri, upstreamResponse.headers);
      if (isPlaylist && request.method != 'HEAD') {
        await _proxyPlaylist(
          request,
          upstreamResponse,
          entry.withSourceUri(
              _responseBaseUri(entry.sourceUri, upstreamResponse)),
        );
        return;
      }

      request.response.statusCode = upstreamResponse.statusCode;
      _copyResponseHeaders(upstreamResponse.headers, request.response.headers);
      if (request.method == 'HEAD') {
        await request.response.close();
        return;
      }
      await upstreamResponse.pipe(request.response);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _proxyPlaylist(
    HttpRequest request,
    HttpClientResponse upstreamResponse,
    _ProxyEntry entry,
  ) async {
    final source = await upstreamResponse.transform(utf8.decoder).join();
    final rewritten = _rewritePlaylist(source, entry);
    final bytes = utf8.encode(rewritten);

    request.response.statusCode = upstreamResponse.statusCode;
    _copyResponseHeaders(
      upstreamResponse.headers,
      request.response.headers,
      skipContentLength: true,
    );
    request.response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    request.response.headers.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  String _rewritePlaylist(String source, _ProxyEntry entry) {
    final lines = const LineSplitter().convert(source);
    final rewritten = lines.map((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        return line;
      }
      if (trimmed.startsWith('#')) {
        return line.replaceAllMapped(
          RegExp(r'URI="([^"]+)"'),
          (match) {
            final uri = _resolvePlaylistUri(entry.sourceUri, match.group(1)!);
            return 'URI="${_register(uri, entry.headers)}"';
          },
        );
      }
      final uri = _resolvePlaylistUri(entry.sourceUri, trimmed);
      return _register(uri, entry.headers);
    }).join('\n');

    return source.endsWith('\n') ? '$rewritten\n' : rewritten;
  }

  Uri _resolvePlaylistUri(Uri base, String uri) {
    final parsed = Uri.parse(uri);
    if (parsed.hasScheme) {
      return parsed;
    }
    return base.resolve(uri);
  }

  void _applySourceHeaders(
    HttpClientRequest request,
    Map<String, String> headers,
  ) {
    for (final entry in headers.entries) {
      if (entry.value.isEmpty) {
        continue;
      }
      request.headers.set(entry.key, entry.value);
    }
  }

  void _forwardRequestHeader(
    HttpRequest from,
    HttpClientRequest to,
    String name,
  ) {
    final value = from.headers.value(name);
    if (value != null && value.isNotEmpty) {
      to.headers.set(name, value);
    }
  }

  bool _isPlaylist(Uri uri, HttpHeaders headers) {
    final contentType = headers.contentType?.mimeType.toLowerCase() ?? '';
    if (contentType.contains('mpegurl') ||
        contentType.contains('x-mpegurl') ||
        contentType.contains('vnd.apple.mpegurl')) {
      return true;
    }
    return uri.path.toLowerCase().endsWith('.m3u8');
  }

  Uri _responseBaseUri(Uri sourceUri, HttpClientResponse response) {
    return response.redirects.fold(
      sourceUri,
      (uri, redirect) => uri.resolveUri(redirect.location),
    );
  }

  void _copyResponseHeaders(
    HttpHeaders from,
    HttpHeaders to, {
    bool skipContentLength = false,
  }) {
    const skipped = {
      HttpHeaders.connectionHeader,
      HttpHeaders.transferEncodingHeader,
      HttpHeaders.contentEncodingHeader,
      'keep-alive',
    };

    from.forEach((name, values) {
      final lower = name.toLowerCase();
      if (skipped.contains(lower)) {
        return;
      }
      if (skipContentLength && lower == HttpHeaders.contentLengthHeader) {
        return;
      }
      to.set(name, values);
    });
  }

  Future<String> _selectAdvertisedHost(String? rendererBaseUrl) async {
    final rendererHost = Uri.tryParse(rendererBaseUrl ?? '')?.host;
    final addresses = await _localIpv4Addresses();
    if (rendererHost != null && rendererHost.isNotEmpty) {
      final rendererAddress = InternetAddress.tryParse(rendererHost);
      if (rendererAddress != null && rendererAddress.isLoopback) {
        return InternetAddress.loopbackIPv4.address;
      }
      final sameSubnet = addresses.where(
        (address) => _same24Subnet(address.address, rendererHost),
      );
      if (sameSubnet.isNotEmpty) {
        return sameSubnet.first.address;
      }
    }
    if (addresses.isNotEmpty) {
      return addresses.first.address;
    }
    return InternetAddress.loopbackIPv4.address;
  }

  Future<List<InternetAddress>> _localIpv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return interfaces
        .expand((interface) => interface.addresses)
        .where((address) =>
            !address.isLoopback && !address.address.startsWith('169.254.'))
        .toList();
  }

  bool _same24Subnet(String left, String right) {
    final leftParts = left.split('.');
    final rightParts = right.split('.');
    if (leftParts.length != 4 || rightParts.length != 4) {
      return false;
    }
    return leftParts[0] == rightParts[0] &&
        leftParts[1] == rightParts[1] &&
        leftParts[2] == rightParts[2];
  }

  void _removeExpiredEntries() {
    final now = DateTime.now();
    _entries.removeWhere(
      (_, entry) => now.difference(entry.createdAt) > _entryLifetime,
    );
  }

  Future<void> _respondText(
    HttpResponse response,
    int statusCode,
    String body,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.text;
    response.write(body);
    await response.close();
  }
}

class _ProxyEntry {
  const _ProxyEntry({
    required this.sourceUri,
    required this.headers,
    required this.createdAt,
  });

  final Uri sourceUri;
  final Map<String, String> headers;
  final DateTime createdAt;

  _ProxyEntry withSourceUri(Uri sourceUri) {
    return _ProxyEntry(
      sourceUri: sourceUri,
      headers: headers,
      createdAt: createdAt,
    );
  }
}
