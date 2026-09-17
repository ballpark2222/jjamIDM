/// Retry behavior owned by the task, executed by the application layer.
final class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 5,
    this.initialDelay = const Duration(seconds: 2),
    this.backoffFactor = 2.0,
    this.maxDelay = const Duration(minutes: 5),
  });

  final int maxAttempts;
  final Duration initialDelay;
  final double backoffFactor;
  final Duration maxDelay;

  static const RetryPolicy never = RetryPolicy(maxAttempts: 0);

  Duration delayForAttempt(int attempt) {
    final ms = initialDelay.inMilliseconds * _pow(backoffFactor, attempt);
    return ms > maxDelay.inMilliseconds
        ? maxDelay
        : Duration(milliseconds: ms.round());
  }

  bool canRetry(int failedAttempts) => failedAttempts < maxAttempts;

  static double _pow(double base, int exp) {
    var result = 1.0;
    for (var i = 0; i < exp; i++) {
      result *= base;
    }
    return result;
  }
}
