/// Where/how the result file is written (design doc §8).
enum ConflictPolicy { rename, overwrite, fail, ask }

final class OutputSpec {
  const OutputSpec({
    required this.targetDirectory,
    this.fileName,
    this.conflictPolicy = ConflictPolicy.rename,
    this.expectedSize,
    this.checksum,
  });

  final String targetDirectory;

  /// Desired filename; when null the engine/server decides and the
  /// resolved name is reported back through task metadata.
  final String? fileName;

  final ConflictPolicy conflictPolicy;

  /// Bytes, when known at queue time.
  final int? expectedSize;

  /// `<algo>:<hex>` e.g. `sha256:...` — verified in VERIFYING state.
  final String? checksum;

  OutputSpec copyWith({
    String? targetDirectory,
    String? fileName,
    ConflictPolicy? conflictPolicy,
    int? expectedSize,
    String? checksum,
  }) => OutputSpec(
    targetDirectory: targetDirectory ?? this.targetDirectory,
    fileName: fileName ?? this.fileName,
    conflictPolicy: conflictPolicy ?? this.conflictPolicy,
    expectedSize: expectedSize ?? this.expectedSize,
    checksum: checksum ?? this.checksum,
  );
}
