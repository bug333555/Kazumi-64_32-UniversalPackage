/// A hint for the native player when the resolved URL is already known to be
/// an HLS playlist.
enum VideoSourceFormat {
  auto,
  hls,
}

/// Returns whether [value] has an unambiguous HLS playlist path.
///
/// Sorani returns signed URLs such as `index.m3u8?timestamp=...`. Looking at
/// the URI path keeps the query string from hiding the extension while still
/// allowing callers to pass a plain local path.
bool isHlsVideoUrl(String value) {
  final parsed = Uri.tryParse(value);
  final path = parsed?.path.isNotEmpty == true
      ? parsed!.path
      : value.split('#').first.split('?').first;
  final normalized = path.toLowerCase();
  return normalized.endsWith('.m3u8') || normalized.endsWith('.m3u');
}
