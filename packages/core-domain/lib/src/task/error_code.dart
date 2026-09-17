/// Engine-agnostic error codes. Adapters normalize provider-specific
/// errors into these (design doc §11: "engine-specific exception →
/// FreeDM ErrorCode 변환").
enum ErrorCode {
  none,
  network,
  timeout,
  connectionDropped,
  httpClientError, // 4xx generic
  httpServerError, // 5xx
  authRequired, // 401
  forbidden, // 403
  notFound, // 404
  urlExpired, // signed-url expiry pattern
  diskFull,
  fileSystemError,
  checksumMismatch,
  cancelledByUser,
  engineUnavailable,
  incompatibleProtocol,
  unsupportedScheme,
  unknown,
}
