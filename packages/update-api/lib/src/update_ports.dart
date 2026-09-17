import 'update_types.dart';

/// Port: where update candidates come from (GitHub releases feed,
/// integration-bundle registry…). Network lives in the impl.
abstract interface class UpdateSource {
  Future<ComponentCandidate?> latestFor(String componentId);
}

/// Port: fetches bundle bytes. Returns the raw archive — the manager
/// stages it; unpacking is store responsibility.
abstract interface class BundleFetcher {
  Future<List<int>> fetch(String bundleUrl);
}

/// Port: detached-signature verification. Dev default is
/// [Sha256OnlyVerifier] (hash check only); release builds plug in
/// minisign/ed25519 against a pinned public key.
abstract interface class SignatureVerifier {
  Future<bool> verify(
      List<int> bundleBytes, ComponentCandidate candidate);
}

/// Port: filesystem layout under `<root>/<componentId>/<version>/`
/// plus an atomic `active` marker. Keeps dart:io out of the manager.
abstract interface class BundleStore {
  /// Extract [bundleBytes] into the version dir; returns its path.
  Future<String> install(
      String componentId, String version, List<int> bundleBytes);

  /// Atomically repoint the active marker (temp file + rename).
  Future<void> activate(String componentId, String version);

  Future<void> delete(String componentId, String version);

  Future<ComponentState> load(String componentId);
  Future<void> save(ComponentState state);
}
