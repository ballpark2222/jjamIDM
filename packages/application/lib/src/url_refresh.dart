import 'package:freedm_core_domain/freedm_core_domain.dart';

/// A replacement source for an expired URL (design doc §20).
/// Metadata fields feed [SameFileValidator]; any subset may be null.
final class RefreshedSource {
  const RefreshedSource({
    required this.url,
    this.etag,
    this.lastModified,
    this.contentLength,
    this.contentType,
  });

  final String url;
  final String? etag;
  final String? lastModified;
  final int? contentLength;
  final String? contentType;
}

enum SameFileVerdict {
  /// At least one strong signal confirms identity (etag match, or
  /// length+lastModified match).
  match,

  /// Nothing comparable — allowed to continue; the refreshed URL
  /// came from a trusted refresh path.
  indeterminate,

  /// A hard signal contradicts identity — partial bytes must NOT be
  /// trusted; the task is failed rather than silently corrupted.
  conflict,
}

/// Port: produce a fresh URL for a task whose source expired
/// (signed-URL 403/410, engine URL_EXPIRED). Implementations can
/// re-fetch `source.originalPageUrl`, replay a site flow, or ask a
/// resolver — they must never see decrypted credentials directly;
/// header resolution stays with [CredentialResolver].
abstract interface class UrlRefreshResolver {
  Future<RefreshedSource> refresh(DownloadTask task);
}

/// No refresh capability — expired URLs fail the task.
final class NullUrlRefreshResolver implements UrlRefreshResolver {
  const NullUrlRefreshResolver();

  @override
  Future<RefreshedSource> refresh(DownloadTask task) =>
      throw UnsupportedError('no url refresh resolver configured');
}

/// Compares stored source metadata with a refreshed source
/// (design doc §20 same-file validation).
final class SameFileValidator {
  const SameFileValidator();

  SameFileVerdict validate(DownloadSource stored, RefreshedSource fresh) {
    var sawSignal = false;

    if (stored.etag != null && fresh.etag != null) {
      sawSignal = true;
      if (!_weakEq(stored.etag!, fresh.etag!)) {
        return SameFileVerdict.conflict;
      }
      return SameFileVerdict.match;
    }
    if (stored.contentLength != null && fresh.contentLength != null) {
      sawSignal = true;
      if (stored.contentLength != fresh.contentLength) {
        return SameFileVerdict.conflict;
      }
    }
    if (stored.lastModified != null && fresh.lastModified != null) {
      sawSignal = true;
      if (stored.lastModified != fresh.lastModified) {
        return SameFileVerdict.conflict;
      }
      // length + lastModified agreeing is a match only if length was
      // also comparable; lastModified alone is weak (1s granularity).
      if (stored.contentLength != null && fresh.contentLength != null) {
        return SameFileVerdict.match;
      }
    }
    if (stored.contentType != null && fresh.contentType != null) {
      sawSignal = true;
      if (stored.contentType != fresh.contentType) {
        return SameFileVerdict.conflict;
      }
    }
    return sawSignal ? SameFileVerdict.match : SameFileVerdict.indeterminate;
  }

  /// ETag equality tolerant of the `W/` weak prefix — a weak and
  /// strong validator with the same tag body still denote the same
  /// representation body.
  bool _weakEq(String a, String b) =>
      _stripWeak(a) == _stripWeak(b);

  String _stripWeak(String tag) =>
      tag.startsWith('W/') ? tag.substring(2) : tag;
}
