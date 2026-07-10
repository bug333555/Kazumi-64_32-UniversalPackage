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
  static const _maxEntries = 4096;

  final _entries = <String, _ProxyEntry>{};
  final _entryTokens = <String, String>{};
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
    final fileName = await _detectFileName(sourceUri, headers);
    return _register(sourceUri, headers, fileName: fileName);
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _advertisedHost = null;
    _entries.clear();
    _entryTokens.clear();
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

  String _register(
    Uri sourceUri,
    Map<String, String> headers, {
    String? fileName,
  }) {
    _removeExpiredEntries();
    final resolvedFileName = fileName ?? _fileNameFor(sourceUri)!;
    final cacheKey = _entryCacheKey(sourceUri, headers, resolvedFileName);
    final existingToken = _entryTokens[cacheKey];
    if (existingToken != null && _entries.containsKey(existingToken)) {
      return _proxyUrl(existingToken, resolvedFileName);
    }

    final token = _newToken();
    _entries[token] = _ProxyEntry(
      sourceUri: sourceUri,
      headers: Map.unmodifiable(headers),
      createdAt: DateTime.now(),
      cacheKey: cacheKey,
      fileName: resolvedFileName,
    );
    _entryTokens[cacheKey] = token;
    _trimEntries();
    return _proxyUrl(token, resolvedFileName);
  }

  String _proxyUrl(String token, String fileName) {
    return Uri(
      scheme: 'http',
      host: _advertisedHost,
      port: _server!.port,
      pathSegments: [
        _proxyPrefix,
        token,
        fileName,
      ],
    ).toString();
  }

  String _entryCacheKey(
    Uri sourceUri,
    Map<String, String> headers,
    String fileName,
  ) {
    final sortedHeaders = headers.entries.toList()
      ..sort((left, right) => left.key
          .toLowerCase()
          .compareTo(right.key.toLowerCase()));
    return jsonEncode([
      sourceUri.toString(),
      fileName,
      for (final header in sortedHeaders)
        [header.key.toLowerCase(), header.value],
    ]);
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
      if (segments.length != 3 || segments.first != _proxyPrefix) {
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
      final upstreamResponse = await _openUpstream(client, request, entry);
      final isPlaylist = _isPlaylist(entry.sourceUri, upstreamResponse.headers);
      if (isPlaylist && request.method != 'HEAD') {
        final responseBaseUri =
            _responseBaseUri(entry.sourceUri, upstreamResponse);
        await _proxyPlaylist(
          request,
          upstreamResponse,
          entry.withSourceUri(
            responseBaseUri,
            headers: _headersForNested(entry, responseBaseUri),
          ),
        );
        return;
      }

      if (request.method == 'HEAD') {
        _writeHeadResponse(upstreamResponse, request.response);
        await request.response.close();
        return;
      }
      request.response.statusCode = upstreamResponse.statusCode;
      _copyResponseHeaders(upstreamResponse.headers, request.response.headers);
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
            return 'URI="${_register(uri, _headersForNested(entry, uri))}"';
          },
        );
      }
      final uri = _resolvePlaylistUri(entry.sourceUri, trimmed);
      return _register(uri, _headersForNested(entry, uri));
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

  Future<HttpClientResponse> _openUpstream(
    HttpClient client,
    HttpRequest request,
    _ProxyEntry entry,
  ) async {
    Future<HttpClientResponse> send({
      required bool head,
      bool fallbackRange = false,
    }) async {
      final upstreamRequest = head
          ? await client.headUrl(entry.sourceUri)
          : await client.getUrl(entry.sourceUri);
      _applySourceHeaders(upstreamRequest, entry.headers);
      _forwardRequestHeader(
          request, upstreamRequest, HttpHeaders.rangeHeader);
      _forwardRequestHeader(
          request, upstreamRequest, HttpHeaders.ifRangeHeader);
      _forwardRequestHeader(
          request, upstreamRequest, HttpHeaders.acceptHeader);
      if (fallbackRange &&
          upstreamRequest.headers.value(HttpHeaders.rangeHeader) == null) {
        upstreamRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      }
      return upstreamRequest.close();
    }

    if (request.method != 'HEAD') {
      return send(head: false);
    }
    final response = await send(head: true);
    if (response.statusCode < 400) {
      return response;
    }
    await response.drain<void>();
    return send(head: false, fallbackRange: true);
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

  Map<String, String> _headersForNested(_ProxyEntry entry, Uri target) {
    if (_sameOrigin(entry.sourceUri, target)) {
      return entry.headers;
    }
    final headers = Map<String, String>.from(entry.headers);
    headers.removeWhere((name, _) {
      final lower = name.toLowerCase();
      return lower == HttpHeaders.cookieHeader ||
          lower == HttpHeaders.authorizationHeader ||
          lower == HttpHeaders.proxyAuthorizationHeader;
    });
    return headers;
  }

  bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  Future<String> _detectFileName(
    Uri sourceUri,
    Map<String, String> headers,
  ) async {
    final inferred = _fileNameFor(sourceUri, allowFallback: false);
    if (inferred != null) {
      return inferred;
    }
    final client = HttpClient();
    try {
      var request = await client.headUrl(sourceUri);
      _applySourceHeaders(request, headers);
      var response = await request.close().timeout(const Duration(seconds: 8));
      final headMime = response.statusCode < 400
          ? response.headers.contentType?.mimeType
          : null;
      final headFileName = headMime == null
          ? null
          : _fileNameFor(
              sourceUri,
              contentType: headMime,
              allowFallback: false,
            );
      await response.drain<void>();
      if (headFileName != null) {
        return headFileName;
      }

      request = await client.getUrl(sourceUri);
      _applySourceHeaders(request, headers);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      response = await request.close().timeout(const Duration(seconds: 8));
      final contentType = response.statusCode < 400
          ? response.headers.contentType?.mimeType
          : null;
      List<int> prefix = const [];
      if (response.statusCode < 400) {
        try {
          prefix = await response.first.timeout(const Duration(seconds: 8));
        } catch (_) {}
      } else {
        await response.drain<void>();
      }
      final prefixText = utf8.decode(
        prefix.take(1024).toList(),
        allowMalformed: true,
      );
      if (prefixText.trimLeft().startsWith('#EXTM3U')) {
        return 'master.m3u8';
      }
      return _fileNameFor(sourceUri, contentType: contentType)!;
    } catch (error) {
      KazumiLogger().w(
        'RemoteStreamProxy: media type probe failed',
        error: error,
      );
      return _fileNameFor(sourceUri)!;
    } finally {
      client.close(force: true);
    }
  }

  String? _fileNameFor(
    Uri uri, {
    String? contentType,
    bool allowFallback = true,
  }) {
    final mime = contentType?.toLowerCase() ?? '';
    if (mime.contains('mpegurl')) {
      return 'master.m3u8';
    }
    if (mime == 'video/mp2t' || mime.contains('mpeg-tts')) {
      return 'segment.ts';
    }
    if (mime == 'video/webm') {
      return 'video.webm';
    }
    if (mime == 'video/x-matroska') {
      return 'video.mkv';
    }
    if (mime == 'video/x-flv') {
      return 'video.flv';
    }
    if (mime == 'video/mp4') {
      return 'video.mp4';
    }

    final candidates = '${uri.path} ${uri.query}';
    final matches = RegExp(
      r'([A-Za-z0-9_.-]+\.(?:m3u8|mp4|mkv|webm|flv|ts|m4s|aac|key|bin))',
      caseSensitive: false,
    ).allMatches(candidates).toList();
    if (matches.isNotEmpty) {
      return matches.last.group(1)!;
    }
    return allowFallback ? 'video.mp4' : null;
  }

  void _copyResponseHeaders(
    HttpHeaders from,
    HttpHeaders to, {
    bool skipContentLength = false,
    bool skipContentRange = false,
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
      if (skipContentRange && lower == HttpHeaders.contentRangeHeader) {
        return;
      }
      to.set(name, values);
    });
  }

  void _writeHeadResponse(
    HttpClientResponse upstream,
    HttpResponse downstream,
  ) {
    final contentRange =
        upstream.headers.value(HttpHeaders.contentRangeHeader);
    final fallbackTotal = contentRange == null
        ? null
        : int.tryParse(contentRange.split('/').last.trim());
    final isRangeProbe = upstream.statusCode == HttpStatus.partialContent &&
        fallbackTotal != null;
    downstream.statusCode =
        isRangeProbe ? HttpStatus.ok : upstream.statusCode;
    _copyResponseHeaders(
      upstream.headers,
      downstream.headers,
      skipContentLength: isRangeProbe,
      skipContentRange: isRangeProbe,
    );
    if (isRangeProbe) {
      downstream.headers.contentLength = fallbackTotal;
    }
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
    final expiredTokens = _entries.entries
        .where(
          (entry) => now.difference(entry.value.createdAt) > _entryLifetime,
        )
        .map((entry) => entry.key)
        .toList();
    for (final token in expiredTokens) {
      _removeEntry(token);
    }
  }

  void _trimEntries() {
    while (_entries.length > _maxEntries) {
      _removeEntry(_entries.keys.first);
    }
  }

  void _removeEntry(String token) {
    final entry = _entries.remove(token);
    if (entry != null && _entryTokens[entry.cacheKey] == token) {
      _entryTokens.remove(entry.cacheKey);
    }
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
    required this.cacheKey,
    required this.fileName,
  });

  final Uri sourceUri;
  final Map<String, String> headers;
  final DateTime createdAt;
  final String cacheKey;
  final String fileName;

  _ProxyEntry withSourceUri(
    Uri sourceUri, {
    Map<String, String>? headers,
  }) {
    return _ProxyEntry(
      sourceUri: sourceUri,
      headers: headers ?? this.headers,
      createdAt: createdAt,
      cacheKey: cacheKey,
      fileName: fileName,
    );
  }
}
