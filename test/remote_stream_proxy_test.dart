import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/remote_stream_proxy.dart';

void main() {
  tearDown(() async {
    await RemoteStreamProxy.instance.stop();
  });

  test('rewrites HLS playlists and keeps source headers for nested assets',
      () async {
    final seenHeaders = <String, Map<String, String?>>{};
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));

    upstream.listen((request) async {
      seenHeaders[request.uri.path] = {
        'user-agent': request.headers.value(HttpHeaders.userAgentHeader),
        'referer': request.headers.value('referer'),
        'cookie': request.headers.value(HttpHeaders.cookieHeader),
      };

      switch (request.uri.path) {
        case '/playlist.m3u8':
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.write('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:4.0,
segment.ts
''');
        case '/key.bin':
          request.response.add(utf8.encode('key-data'));
        case '/segment.ts':
          request.response.add(utf8.encode('segment-data'));
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final source = Uri(
      scheme: 'http',
      host: upstream.address.host,
      port: upstream.port,
      path: '/playlist.m3u8',
    );
    final proxyUrl = await RemoteStreamProxy.instance.prepare(
      source.toString(),
      headers: const {
        'user-agent': 'KazumiTestUA',
        'referer': 'https://source.example/watch',
        'cookie': 'session=abc',
      },
      rendererBaseUrl: 'http://127.0.0.1:9000',
    );
    expect(Uri.parse(proxyUrl).path, endsWith('/playlist.m3u8'));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final playlist = await _getString(client, Uri.parse(proxyUrl));
    final repeatedPlaylist = await _getString(client, Uri.parse(proxyUrl));
    expect(playlist, contains('/stream/'));
    expect(repeatedPlaylist, playlist);
    expect(playlist, isNot(contains('\nsegment.ts')));
    expect(playlist, isNot(contains('URI="key.bin"')));

    final keyUrl = RegExp(r'URI="([^"]+)"').firstMatch(playlist)!.group(1)!;
    expect(await _getString(client, Uri.parse(keyUrl)), 'key-data');

    final segmentUrl = playlist
        .split('\n')
        .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
    expect(await _getString(client, Uri.parse(segmentUrl)), 'segment-data');

    expect(seenHeaders['/playlist.m3u8']!['user-agent'], 'KazumiTestUA');
    expect(seenHeaders['/playlist.m3u8']!['referer'],
        'https://source.example/watch');
    expect(seenHeaders['/playlist.m3u8']!['cookie'], 'session=abc');
    expect(seenHeaders['/key.bin']!['user-agent'], 'KazumiTestUA');
    expect(
        seenHeaders['/segment.ts']!['referer'], 'https://source.example/watch');
  });

  test('forwards range requests for direct media URLs', () async {
    String? seenRange;
    String? seenIfRange;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));

    upstream.listen((request) async {
      seenRange = request.headers.value(HttpHeaders.rangeHeader);
      seenIfRange = request.headers.value(HttpHeaders.ifRangeHeader);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 2-5/10',
      );
      request.response.add(utf8.encode('cdef'));
      await request.response.close();
    });

    final source = Uri(
      scheme: 'http',
      host: upstream.address.host,
      port: upstream.port,
      path: '/video.mp4',
    );
    final proxyUrl = await RemoteStreamProxy.instance.prepare(
      source.toString(),
      headers: const {'user-agent': 'KazumiTestUA'},
      rendererBaseUrl: 'http://127.0.0.1:9000',
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(Uri.parse(proxyUrl));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-5');
    request.headers.set(HttpHeaders.ifRangeHeader, '"test-etag"');
    final response = await request.close();

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
        response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2-5/10');
    expect(await response.transform(utf8.decoder).join(), 'cdef');
    expect(seenRange, 'bytes=2-5');
    expect(seenIfRange, '"test-etag"');
  });

  test('adds a renderer-friendly extension when the source URL has none',
      () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));

    upstream.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      request.response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
      request.response.write('#EXTM3U\n');
      await request.response.close();
    });

    final source = Uri(
      scheme: 'http',
      host: upstream.address.host,
      port: upstream.port,
      path: '/protected-stream',
    );
    final proxyUrl = await RemoteStreamProxy.instance.prepare(
      source.toString(),
      headers: const {'user-agent': 'KazumiTestUA'},
      rendererBaseUrl: 'http://127.0.0.1:9000',
    );

    expect(Uri.parse(proxyUrl).path, endsWith('/master.m3u8'));
  });

  test('normalizes a HEAD range fallback to the full resource length',
      () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));

    upstream.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      } else {
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=0-0');
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-0/1000',
        );
        request.response.headers.contentLength = 1;
        request.response.add(const [0]);
      }
      await request.response.close();
    });

    final source = Uri(
      scheme: 'http',
      host: upstream.address.host,
      port: upstream.port,
      path: '/video.mp4',
    );
    final proxyUrl = await RemoteStreamProxy.instance.prepare(
      source.toString(),
      headers: const {'user-agent': 'KazumiTestUA'},
      rendererBaseUrl: 'http://127.0.0.1:9000',
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.headUrl(Uri.parse(proxyUrl));
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentLength, 1000);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), isNull);
  });

  test('does not forward cookies to cross-origin HLS assets', () async {
    String? crossOriginCookie;
    final assetServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => assetServer.close(force: true));
    assetServer.listen((request) async {
      crossOriginCookie = request.headers.value(HttpHeaders.cookieHeader);
      request.response.add(utf8.encode('segment-data'));
      await request.response.close();
    });

    final playlistServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => playlistServer.close(force: true));
    playlistServer.listen((request) async {
      request.response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
      request.response.write(
        '#EXTM3U\nhttp://${assetServer.address.host}:${assetServer.port}/segment.ts\n',
      );
      await request.response.close();
    });

    final source = Uri(
      scheme: 'http',
      host: playlistServer.address.host,
      port: playlistServer.port,
      path: '/playlist.m3u8',
    );
    final proxyUrl = await RemoteStreamProxy.instance.prepare(
      source.toString(),
      headers: const {
        'user-agent': 'KazumiTestUA',
        'cookie': 'session=secret',
      },
      rendererBaseUrl: 'http://127.0.0.1:9000',
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final playlist = await _getString(client, Uri.parse(proxyUrl));
    final segmentUrl = playlist
        .split('\n')
        .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
    expect(await _getString(client, Uri.parse(segmentUrl)), 'segment-data');
    expect(crossOriginCookie, isNull);
  });

  test('does not drain a full response when a CDN ignores HEAD fallback range',
      () async {
    final allowUpstreamFinish = Completer<void>();
    addTearDown(() {
      if (!allowUpstreamFinish.isCompleted) {
        allowUpstreamFinish.complete();
      }
    });
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((request) async {
      if (request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentLength = 1000;
      try {
        request.response.add(const [0]);
        await request.response.flush();
        await allowUpstreamFinish.future;
        request.response.add(List<int>.filled(999, 0));
        await request.response.close();
      } catch (_) {}
    });

    final source = Uri(
      scheme: 'http',
      host: upstream.address.host,
      port: upstream.port,
      path: '/video.mp4',
    );
    final proxyUrl = await RemoteStreamProxy.instance.prepare(
      source.toString(),
      headers: const {'user-agent': 'KazumiTestUA'},
      rendererBaseUrl: 'http://127.0.0.1:9000',
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.headUrl(Uri.parse(proxyUrl));
    final response = await request.close().timeout(
          const Duration(seconds: 1),
        );
    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentLength, 1000);
    allowUpstreamFinish.complete();
  });
}

Future<String> _getString(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  return response.transform(utf8.decoder).join();
}
