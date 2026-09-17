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
