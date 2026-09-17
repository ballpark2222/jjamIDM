class DownloadItemModel {
  int? id;

  String uid;

  String fileName;

  String filePath;

  String downloadUrl;

  DateTime? startDate;

  int fileSize;

  DateTime? finishDate;

  double progress;

  String fileType;

  bool supportsPause;

  String status;

  /// FreeDM patch 0002: caller-supplied request headers
  /// (Cookie / Referer / Authorization / custom). Merged after the
  /// engine's own defaults so callers can override them.
  Map<String, String> headers;

  DownloadItemModel({
    this.id,
    this.uid = "",
    required this.fileName,
    this.filePath = '',
    required this.downloadUrl,
    this.startDate,
    this.finishDate,
    required this.progress,
    this.fileSize = 0,
    this.fileType = "other",
    this.supportsPause = false,
    this.status = "In Queue",
    this.headers = const {},
  });
}
