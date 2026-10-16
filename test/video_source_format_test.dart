import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

void main() {
  test('recognizes signed HLS URLs by their path extension', () {
    expect(
      isHlsVideoUrl(
        'https://example.test/video/index.m3u8?timestamp=123&key=abc',
      ),
      isTrue,
    );
    expect(isHlsVideoUrl('/cache/episode.m3u'), isTrue);
  });

  test('does not classify ordinary media or error pages as HLS', () {
    expect(isHlsVideoUrl('https://example.test/video.mp4?source=m3u8'), isFalse);
    expect(isHlsVideoUrl('https://example.test/expired'), isFalse);
  });
}
