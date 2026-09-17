/// What an engine can do (design doc §10). UI/routers read this —
/// they never infer capability from provider names.
final class EngineCapabilities {
  const EngineCapabilities({
    this.segmentedDownload = false,
    this.dynamicConnections = false,
    this.resume = false,
    this.customHeaders = false,
    this.cookies = false,
    this.referer = false,
    this.proxy = false,
    this.speedLimit = false,
    this.http2 = false,
    this.ftp = false,
    this.torrent = false,
  });

  final bool segmentedDownload;
  final bool dynamicConnections;
  final bool resume;
  final bool customHeaders;
  final bool cookies;
  final bool referer;
  final bool proxy;
  final bool speedLimit;
  final bool http2;
  final bool ftp;
  final bool torrent;

  factory EngineCapabilities.fromJson(Map<String, Object?> json) =>
      EngineCapabilities(
        segmentedDownload: json['segmentedDownload'] == true,
        dynamicConnections: json['dynamicConnections'] == true,
        resume: json['resume'] == true,
        customHeaders: json['customHeaders'] == true,
        cookies: json['cookies'] == true,
        referer: json['referer'] == true,
        proxy: json['proxy'] == true,
        speedLimit: json['speedLimit'] == true,
        http2: json['http2'] == true,
        ftp: json['ftp'] == true,
        torrent: json['torrent'] == true,
      );

  Map<String, Object?> toJson() => {
    'segmentedDownload': segmentedDownload,
    'dynamicConnections': dynamicConnections,
    'resume': resume,
    'customHeaders': customHeaders,
    'cookies': cookies,
    'referer': referer,
    'proxy': proxy,
    'speedLimit': speedLimit,
    'http2': http2,
    'ftp': ftp,
    'torrent': torrent,
  };
}
