/// Port: turns credential/header references into request headers
/// right before engine dispatch (design doc §14).
///
/// The DPAPI-backed implementation arrives with the native host (M5);
/// secrets never touch the task DB — only `credential://<uuid>` and
/// `headers://<uuid>` refs are persisted.
abstract interface class CredentialResolver {
  Future<Map<String, String>> resolveHeaders({
    String? credentialRef,
    String? headersRef,
  });
}

/// No stored credentials — anonymous downloads only.
final class NullCredentialResolver implements CredentialResolver {
  const NullCredentialResolver();

  @override
  Future<Map<String, String>> resolveHeaders({
    String? credentialRef,
    String? headersRef,
  }) async =>
      const {};
}

/// Session-scoped credential store: mints opaque `headers://` refs
/// at enqueue and resolves them at dispatch. Values live only in
/// process memory — never written to the task DB — matching both
/// the design's "no secrets on disk" rule and the real lifetime of
/// a browser session header. A ref that outlives the process simply
/// resolves to anonymous headers (cookie-gated URLs then fail as
/// forbidden/urlExpired and take the refresh path honestly).
final class SessionCredentialResolver implements CredentialResolver {
  final _headers = <String, Map<String, String>>{};
  var _seq = 0;

  /// Store [headers], returning the ref to persist on the task's
  /// source — safe to put in the DB since it's an opaque pointer.
  String storeHeaders(Map<String, String> headers) {
    final ref = 'headers://s${_seq++}';
    _headers[ref] = Map.unmodifiable(headers);
    return ref;
  }

  @override
  Future<Map<String, String>> resolveHeaders({
    String? credentialRef,
    String? headersRef,
  }) async =>
      _headers[headersRef] ?? const {};
}
