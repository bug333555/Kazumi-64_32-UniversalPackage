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
      },
      rendererBaseUrl: 'http://127.0.0.1:9000',
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final playlist = await _getString(client, Uri.parse(proxyUrl));
    expect(playlist, contains('/stream/'));
    expect(playlist, isNot(contains('segment.ts')));
    expect(playlist, isNot(contains('key.bin')));

    final keyUrl = RegExp(r'URI="([^"]+)"').firstMatch(playlist)!.group(1)!;
    expect(await _getString(client, Uri.parse(keyUrl)), 'key-data');

    final segmentUrl = playlist
        .split('\n')
        .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
    expect(await _getString(client, Uri.parse(segmentUrl)), 'segment-data');

    expect(seenHeaders['/playlist.m3u8']!['user-agent'], 'KazumiTestUA');
    expect(seenHeaders['/playlist.m3u8']!['referer'],
        'https://source.example/watch');
    expect(seenHeaders['/key.bin']!['user-agent'], 'KazumiTestUA');
    expect(
        seenHeaders['/segment.ts']!['referer'], 'https://source.example/watch');
  });

  test('forwards range requests for direct media URLs', () async {
    String? seenRange;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));

    upstream.listen((request) async {
      seenRange = request.headers.value(HttpHeaders.rangeHeader);
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
    final response = await request.close();

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
        response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2-5/10');
    expect(await response.transform(utf8.decoder).join(), 'cdef');
    expect(seenRange, 'bytes=2-5');
  });
}

Future<String> _getString(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  return response.transform(utf8.decoder).join();
}
