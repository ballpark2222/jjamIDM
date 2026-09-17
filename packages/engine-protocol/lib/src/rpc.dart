import 'dart:convert';

/// JSON-RPC 2.0-style wire codec for DownloadEngine Protocol v1.
///
/// Transport: newline-delimited JSON (one message per line) over
/// stdin/stdout — the Engine Host is spawned as a child process, so
/// no socket/port management is needed and no network surface exists.
sealed class RpcMessage {
  const RpcMessage();

  static RpcMessage? decodeLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    final json = jsonDecode(trimmed);
    if (json is! Map<String, Object?>) {
      throw const FormatException('rpc message is not a JSON object');
    }
    if (json.containsKey('method')) {
      return RpcRequest(
        id: json['id'],
        method: json['method'] as String,
        params: (json['params'] as Map?)?.cast<String, Object?>() ??
            const {},
      );
    }
    if (json.containsKey('result')) {
      return RpcResponse.ok(
          json['id'], (json['result'] as Map).cast<String, Object?>());
    }
    if (json.containsKey('error')) {
      final e = (json['error'] as Map).cast<String, Object?>();
      return RpcResponse.err(
        json['id'],
        RpcError(e['code'] as int, e['message'] as String),
      );
    }
    throw const FormatException('unrecognized rpc frame');
  }
}

final class RpcRequest extends RpcMessage {
  const RpcRequest({
    required this.id,
    required this.method,
    required this.params,
  });

  final Object? id; // int | string | null (notification)
  final String method;
  final Map<String, Object?> params;

  String encode() => jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
}

final class RpcResponse extends RpcMessage {
  const RpcResponse._({required this.id, this.result, this.error});

  factory RpcResponse.ok(Object? id, Map<String, Object?> result) =>
      RpcResponse._(id: id, result: result);

  factory RpcResponse.err(Object? id, RpcError error) =>
      RpcResponse._(id: id, error: error);

  final Object? id;
  final Map<String, Object?>? result;
  final RpcError? error;

  String encode() => jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        if (result != null) 'result': result,
        if (error != null)
          'error': {'code': error!.code, 'message': error!.message},
      });
}

final class RpcError {
  const RpcError(this.code, this.message);
  final int code;
  final String message;

  // application codes (JSON-RPC reserves -32768..-32000)
  static const int engineError = 1000;
  static const int unsupported = 1001;
  static const int badRequest = 1002;
  static const int taskNotFound = 1003;
}

/// Server → client unsolicited message (progress, completion, failure).
final class RpcNotification extends RpcMessage {
  const RpcNotification({required this.method, required this.params});

  final String method;
  final Map<String, Object?> params;

  String encode() => jsonEncode({
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      });
}
