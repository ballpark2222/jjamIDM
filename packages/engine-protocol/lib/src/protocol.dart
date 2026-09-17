/// DownloadEngine Protocol v1 — method names and shared constants
/// (design doc §4.2). Pure data; no I/O.
final class EngineProtocol {
  EngineProtocol._();

  static const int version = 1;

  // commands
  static const String hello = 'engine.hello';
  static const String capabilities = 'engine.capabilities';
  static const String taskProbe = 'task.probe';
  static const String taskCreate = 'task.create';
  static const String taskStart = 'task.start';
  static const String taskPause = 'task.pause';
  static const String taskResume = 'task.resume';
  static const String taskCancel = 'task.cancel';
  static const String taskCheckpoint = 'task.checkpoint';
  static const String taskStatus = 'task.status';
  static const String taskReplaceSource = 'task.replaceSource';
  static const String taskSetSpeedLimit = 'task.setSpeedLimit';
  static const String taskSubscribeEvents = 'task.subscribeEvents';
  static const String selfTest = 'engine.selfTest';
  static const String shutdown = 'engine.shutdown';

  // server → client notifications
  static const String taskEvent = 'task.event';
}
