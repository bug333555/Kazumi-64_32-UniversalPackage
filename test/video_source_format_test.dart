import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

void main() {
  test('detects signed HLS playlist URLs from their path', () {
    expect(
      isHlsVideoUrl('https://cdn.example/index.m3u8?token=abc'),
      isTrue,
    );
    expect(isHlsVideoUrl('https://cdn.example/video.mp4?token=abc'), isFalse);
  });
}
