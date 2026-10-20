enum VideoSourceFormat { auto, hls }

/// Returns whether [value] has an unambiguous HLS playlist path.
bool isHlsVideoUrl(String value) {
  final parsed = Uri.tryParse(value);
  final path = parsed?.path.isNotEmpty == true
      ? parsed!.path
      : value.split('#').first.split('?').first;
  final normalized = path.toLowerCase();
  return normalized.endsWith('.m3u8') || normalized.endsWith('.m3u');
}
