/// Where a download comes from, incl. the metadata needed for the
/// URL-refresh / same-file-validation workflow (design doc §20).
final class DownloadSource {
  const DownloadSource({
    required this.initialUrl,
    this.originalPageUrl,
    this.currentUrl,
    this.finalUrl,
    this.referer,
    this.userAgent,
    this.headersRef,
    this.credentialRef,
    this.etag,
    this.lastModified,
    this.contentLength,
    this.contentType,
  });

  /// Page the user was on when the download was initiated.
  final String? originalPageUrl;

  /// URL as first captured.
  final String initialUrl;

  /// URL currently in use (updated on URL refresh).
  final String? currentUrl;

  /// Post-redirect URL once known.
  final String? finalUrl;

  final String? referer;
  final String? userAgent;

  /// Reference to stored headers — never the headers themselves.
  final String? headersRef;

  /// `credential://<uuid>` — secrets never live on the task.
  final String? credentialRef;

  // Same-file validation metadata.
  final String? etag;
  final String? lastModified;
  final int? contentLength;
  final String? contentType;

  String get effectiveUrl => currentUrl ?? finalUrl ?? initialUrl;

  DownloadSource copyWith({
    String? originalPageUrl,
    String? initialUrl,
    String? currentUrl,
    String? finalUrl,
    String? referer,
    String? userAgent,
    String? headersRef,
    String? credentialRef,
    String? etag,
    String? lastModified,
    int? contentLength,
    String? contentType,
  }) => DownloadSource(
    originalPageUrl: originalPageUrl ?? this.originalPageUrl,
    initialUrl: initialUrl ?? this.initialUrl,
    currentUrl: currentUrl ?? this.currentUrl,
    finalUrl: finalUrl ?? this.finalUrl,
    referer: referer ?? this.referer,
    userAgent: userAgent ?? this.userAgent,
    headersRef: headersRef ?? this.headersRef,
    credentialRef: credentialRef ?? this.credentialRef,
    etag: etag ?? this.etag,
    lastModified: lastModified ?? this.lastModified,
    contentLength: contentLength ?? this.contentLength,
    contentType: contentType ?? this.contentType,
  );
}
