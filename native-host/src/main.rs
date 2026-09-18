//! jjamIDM native messaging host (Browser Protocol v1).
//!
//! Chrome/Edge native messaging framing on stdin/stdout:
//!   [u32 little-endian length][UTF-8 JSON message]
//!
//! The host validates every inbound message (allowed commands, URL
//! scheme allowlist, size limits, origin check via argv) and forwards
//! work to the Engine Host over NDJSON-RPC on the child's stdio —
//! engine-host is spawned on demand (cold launch), never via a shell,
//! so there is no command-injection surface.

use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::env;
use std::io::{self, Read, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::thread;

const PROTOCOL_VERSION: u32 = 1;
const MAX_MESSAGE_BYTES: u32 = 1 << 20; // 1 MiB hard cap
const MAX_URL_LEN: usize = 8192;

/// Commands the extension may invoke (design doc: browser protocol v1).
const ALLOWED_COMMANDS: &[&str] = &[
    "ping",
    "download",
    "media",
    "start",
    "pause",
    "resume",
    "cancel",
    "status",
    "reveal",
    "open",
    "pickFolder",
];

#[derive(Debug, Deserialize)]
struct BrowserMessage {
    protocol: u32,
    #[serde(rename = "requestId")]
    request_id: Value,
    command: String,
    #[serde(default)]
    payload: Map<String, Value>,
    // source/extensionVersion are validated for presence, not trusted.
    #[serde(default)]
    source: Option<String>,
    #[serde(rename = "extensionVersion", default)]
    extension_version: Option<String>,
}

#[derive(Debug)]
struct Config {
    /// chrome-extension://<id>/ origins allowed to talk to us.
    allowed_origins: Vec<String>,
    /// argv vector for the engine host (cold launch). Empty = disabled.
    engine_command: Vec<String>,
    /// Working dir for the engine child.
    engine_cwd: Option<String>,
    /// Download target dir — set host-side only; the browser payload
    /// can never dictate a filesystem path (injection guard).
    download_dir: Option<String>,
    /// Scheduler concurrency for the browser-owned engine host.
    max_concurrent: u32,
    /// Persistent queue dir for the scheduler (task repo JSON).
    queue_dir: Option<String>,
    /// This config file's own path — pickedDirs persists back here.
    path: Option<String>,
    /// Absolute dirs the user physically chose in the OS folder
    /// picker. These are the ONLY non-downloadDir roots a download
    /// may target — the extension cannot invent one.
    picked_dirs: Vec<String>,
}

fn load_config() -> Config {
    // %APPDATA%\jjamIDM\native-host.json (or JJAMIDM_NATIVE_HOST_CONFIG;
    // FREEDM_NATIVE_HOST_CONFIG kept as a legacy fallback).
    let path = env::var("JJAMIDM_NATIVE_HOST_CONFIG")
        .ok()
        .or_else(|| env::var("FREEDM_NATIVE_HOST_CONFIG").ok())
        .or_else(|| {
            env::var("APPDATA")
                .ok()
                .map(|d| format!("{}\\jjamIDM\\native-host.json", d))
    });
    let mut cfg = Config {
        allowed_origins: vec![],
        engine_command: vec![],
        engine_cwd: None,
        download_dir: None,
        max_concurrent: 3,
        // Scheduler queue persists next to this config file so held
        // and in-flight browser tasks survive a host restart.
        queue_dir: path.as_deref().and_then(|p| {
            std::path::Path::new(p)
                .parent()
                .map(|d| d.join("queue").to_string_lossy().into_owned())
        }),
        path: path.clone(),
        picked_dirs: vec![],
    };
    if let Some(p) = path {
        if let Ok(raw) = std::fs::read_to_string(&p) {
            if let Ok(j) = serde_json::from_str::<Value>(&raw) {
                if let Some(list) = j.get("allowedOrigins").and_then(|v| v.as_array()) {
                    cfg.allowed_origins = list
                        .iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect();
                }
                if let Some(cmd) = j.get("engineCommand").and_then(|v| v.as_array()) {
                    cfg.engine_command = cmd
                        .iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect();
                }
                cfg.engine_cwd = j
                    .get("engineCwd")
                    .and_then(|v| v.as_str())
                    .map(str::to_string);
                cfg.download_dir = j
                    .get("downloadDir")
                    .and_then(|v| v.as_str())
                    .map(str::to_string);
                if let Some(n) = j.get("maxConcurrent").and_then(|v| v.as_u64()) {
                    cfg.max_concurrent = n.clamp(1, 16) as u32;
                }
                // Only an explicit non-empty string overrides the
                // default <configDir>\queue — an absent key must not
                // silently turn queue mode off (upgrade path).
                if let Some(q) = j
                    .get("queueDir")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty())
                {
                    cfg.queue_dir = Some(q.to_string());
                }
                if let Some(list) =
                    j.get("pickedDirs").and_then(|v| v.as_array())
                {
                    cfg.picked_dirs = list
                        .iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect();
                }
            }
        }
    }
    cfg
}

/// argv[1] carries the extension origin, e.g. chrome-extension://id/
/// (Edge uses the same scheme for MV3 extensions).
fn check_origin(args: &[String], cfg: &Config) -> Result<(), String> {
    let origin = args.get(1).map(String::as_str).unwrap_or("");
    if cfg.allowed_origins.iter().any(|o| o == origin) {
        Ok(())
    } else {
        Err(format!("origin not allowed: {}", origin))
    }
}

fn validate_url(url: &str) -> Result<(), String> {
    if url.is_empty() || url.len() > MAX_URL_LEN {
        return Err("url length out of bounds".into());
    }
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("url scheme not allowed (http/https only)".into());
    }
    // Reject control chars outright — defense against header injection
    // if a URL ever reaches a header.
    if url.chars().any(|c| c.is_control()) {
        return Err("url contains control characters".into());
    }
    Ok(())
}

fn validate_path_component(s: &str) -> Result<(), String> {
    // suggestedFilename must be a bare name — no separators/traversal.
    if s.is_empty() || s.len() > 255 {
        return Err("suggestedFilename length out of bounds".into());
    }
    if s.contains('/') || s.contains('\\') || s.contains("..") || s.contains(':') {
        return Err("suggestedFilename contains path characters".into());
    }
    if s.chars().any(|c| c.is_control()) {
        return Err("suggestedFilename contains control characters".into());
    }
    Ok(())
}

/// `subdir` may name a nested folder under downloadDir — never an
/// absolute path or a traversal out of it. Returns the sanitized
/// relative path (backslash-separated).
fn validate_subdir(s: &str) -> Result<String, String> {
    if s.is_empty() || s.len() > 255 {
        return Err("subdir length out of bounds".into());
    }
    if s.chars().any(|c| c.is_control()) {
        return Err("subdir contains control characters".into());
    }
    let norm = s.replace('/', "\\");
    if norm.starts_with('\\') || norm.contains(':') {
        return Err("subdir must be relative".into());
    }
    for seg in norm.split('\\') {
        if seg.is_empty() || seg == "." || seg == ".." {
            return Err("subdir contains invalid segment".into());
        }
    }
    Ok(norm)
}

/// canonicalize() yields \\?\ verbatim paths — neither explorer.exe
/// nor argv consumers accept them. UNC paths get `\\?\UNC\a\b`,
/// which must fold back to `\\a\b`, not `UNC\a\b`.
fn deverbatim(canon: &std::path::Path) -> String {
    let s = canon.to_string_lossy();
    if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
        format!("\\\\{}", rest)
    } else {
        s.trim_start_matches(r"\\?\").to_string()
    }
}

/// Record a user-picked absolute dir into pickedDirs (deduped) and
/// write it back to the config file — picked dirs must survive a
/// restart or open/reveal would refuse files already saved there.
fn persist_picked_dir(cfg: &mut Config, dir: &str) {
    if cfg.picked_dirs.iter().any(|d| d == dir) {
        return;
    }
    cfg.picked_dirs.push(dir.to_string());
    let Some(p) = cfg.path.clone() else { return };
    let mut j = std::fs::read_to_string(&p)
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .unwrap_or_else(|| json!({}));
    j["pickedDirs"] = json!(cfg.picked_dirs);
    if let Some(parent) = std::path::Path::new(&p).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(
        &p,
        serde_json::to_string_pretty(&j).unwrap_or_default(),
    );
}

// --------------------------------------------------------------------
// Engine-host child process (NDJSON-RPC client)
// --------------------------------------------------------------------

struct EngineClient {
    _child: Child,
    stdin: ChildStdin,
    /// Lines read off the child's stdout by the pump thread.
    lines: Receiver<String>,
    next_id: AtomicU64,
    /// Task-event notifications get forwarded to the browser.
    pending_events: Receiver<Value>,
}

fn spawn_engine(cfg: &Config) -> Result<EngineClient, String> {
    if cfg.engine_command.is_empty() {
        return Err("engineCommand not configured".into());
    }
    let mut cmd = Command::new(&cfg.engine_command[0]);
    cmd.args(&cfg.engine_command[1..]);
    // Browser-spawned engines run in queue mode — scheduler-owned
    // concurrency/retry/persistence instead of raw create+start.
    if let Some(q) = &cfg.queue_dir {
        cmd.arg("--queue").arg(q);
    }
    cmd.arg("--max-concurrent")
        .arg(cfg.max_concurrent.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(cwd) = &cfg.engine_cwd {
        cmd.current_dir(cwd);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("spawn engine-host failed: {}", e))?;
    let stdin = child.stdin.take().ok_or("engine stdin missing")?;
    let stdout: ChildStdout = child.stdout.take().ok_or("engine stdout missing")?;

    // Pump thread: split stdout into lines; RPC responses go to
    // `lines`, task.event notifications go to `pending_events`.
    let (line_tx, line_rx) = mpsc::channel::<String>();
    let (event_tx, event_rx) = mpsc::channel::<Value>();
    thread::spawn(move || {
        let mut reader = io::BufReader::new(stdout);
        let mut buf = Vec::new();
        let mut byte = [0u8; 1];
        loop {
            match reader.read(&mut byte) {
                Ok(0) => break, // EOF — engine exited
                Ok(_) => {
                    if byte[0] == b'\n' {
                        if let Ok(line) = String::from_utf8(buf.clone()) {
                            let t = line.trim();
                            if !t.is_empty() {
                                if let Ok(v) = serde_json::from_str::<Value>(t) {
                                    let mth = v.get("method").and_then(|m| m.as_str());
                                    if mth == Some("task.event")
                                        || mth == Some("media.event")
                                    {
                                        let _ = event_tx.send(v);
                                        buf.clear();
                                        continue;
                                    }
                                }
                                let _ = line_tx.send(line);
                            }
                        }
                        buf.clear();
                    } else {
                        buf.push(byte[0]);
                        if buf.len() as u32 > MAX_MESSAGE_BYTES {
                            break; // runaway output — drop the engine
                        }
                    }
                }
                Err(_) => break,
            }
        }
    });

    Ok(EngineClient {
        _child: child,
        stdin,
        lines: line_rx,
        next_id: AtomicU64::new(1),
        pending_events: event_rx,
    })
}

impl EngineClient {
    /// Send an NDJSON-RPC request, wait for the matching response id.
    fn call(
        &mut self,
        method: &str,
        params: Map<String, Value>,
    ) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let req = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": Value::Object(params),
        });
        let mut line = serde_json::to_string(&req).map_err(|e| e.to_string())?;
        line.push('\n');
        self.stdin
            .write_all(line.as_bytes())
            .and_then(|_| self.stdin.flush())
            .map_err(|e| format!("engine write failed: {}", e))?;

        // Wait for the response with this id; other responses are
        // stale — drop them. Notifications were already siphoned off.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        loop {
            let remain = deadline.saturating_duration_since(std::time::Instant::now());
            if remain.is_zero() {
                return Err("engine response timeout".into());
            }
            match self.lines.recv_timeout(remain) {
                Ok(line) => {
                    let v: Value = serde_json::from_str(line.trim())
                        .map_err(|e| format!("engine sent non-JSON: {}", e))?;
                    if v.get("id").and_then(|i| i.as_u64()) == Some(id) {
                        if let Some(err) = v.get("error") {
                            return Err(format!(
                                "engine error {}: {}",
                                err.get("code").and_then(|c| c.as_i64()).unwrap_or(-1),
                                err.get("message")
                                    .and_then(|m| m.as_str())
                                    .unwrap_or("unknown")
                            ));
                        }
                        return Ok(v.get("result").cloned().unwrap_or(Value::Null));
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    return Err("engine response timeout".into())
                }
                Err(_) => return Err("engine channel closed".into()),
            }
        }
    }
}

impl Drop for EngineClient {
    /// The host owns the engine's lifecycle: ask it to exit cleanly
    /// (flushes queue persistence), then force-kill whatever is left.
    /// An orphaned engine-host would keep writing to shared segment
    /// temp files while the next host's recovery restarts the same
    /// tasks — a double-writer corruption window.
    fn drop(&mut self) {
        let bye = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"engine.shutdown\",\"params\":{}}\n";
        if self
            .stdin
            .write_all(bye.as_bytes())
            .and_then(|_| self.stdin.flush())
            .is_ok()
        {
            // The server drains scheduler + media persistence on
            // shutdown — worst case 2×5s. Killing earlier would
            // truncate the flush this handshake exists to protect.
            for _ in 0..240 {
                match self._child.try_wait() {
                    Ok(Some(_)) => return,
                    _ => thread::sleep(std::time::Duration::from_millis(50)),
                }
            }
        }
        let _ = self._child.kill();
        let _ = self._child.wait();
    }
}

/// Call through the cached engine. Transport-level failures (write
/// error, timeout, closed channel) mean the child is dead or wedged —
/// drop it so the next command respawns instead of reusing a corpse.
/// RPC-level errors ("engine error N: …") leave the engine in place.
fn engine_call(
    engine: &mut Option<EngineClient>,
    method: &str,
    params: Map<String, Value>,
) -> Result<Value, String> {
    let e = engine.as_mut().ok_or("engine not running")?;
    match e.call(method, params) {
        Ok(v) => Ok(v),
        Err(err) => {
            if !err.starts_with("engine error") {
                *engine = None;
            }
            Err(err)
        }
    }
}

/// Spawn the engine if needed, then replay task.subscribeEvents for
/// every task the browser still cares about. A respawned process
/// lost every subscription the previous engine had — without the
/// replay, queue-recovered tasks keep downloading but no
/// progress/terminal event ever reaches the browser again.
fn ensure_engine(
    engine: &mut Option<EngineClient>,
    cfg: &Config,
    subs: &mut BTreeSet<String>,
) -> Result<(), String> {
    if engine.is_some() {
        return Ok(());
    }
    let mut e = spawn_engine(cfg)?;
    let mut dead = Vec::new();
    for id in subs.iter() {
        let mut p = Map::new();
        p.insert("taskId".into(), json!(id));
        match e.call("task.subscribeEvents", p) {
            // RPC error = task is terminal/gone on the new host —
            // prune it so a dead id isn't replayed on every respawn.
            // A transport error means the pipe is dead.
            Err(err) if err.starts_with("engine error") => dead.push(id.clone()),
            Err(err) => return Err(err),
            Ok(_) => {}
        }
    }
    for id in dead {
        subs.remove(&id);
    }
    *engine = Some(e);
    Ok(())
}

/// A download command that failed after `task.create` may have left
/// a persisted parked task on the queue — respawn the engine (the
/// transport failure already dropped it) and cancel the id so the
/// extension's browser fallback doesn't produce a duplicate download
/// later. Best-effort: a task that was never created just errors.
fn compensate_created(
    engine: &mut Option<EngineClient>,
    cfg: &Config,
    subs: &mut BTreeSet<String>,
    task_id: &str,
) {
    subs.remove(task_id);
    if ensure_engine(engine, cfg, subs).is_err() {
        return;
    }
    let mut p = Map::new();
    p.insert("taskId".into(), json!(task_id));
    let _ = engine_call(engine, "task.cancel", p);
}

/// Terminal events end the server-side subscription — the id can
/// leave the replay set. media.event carries a TaskCodec snapshot
/// under `task`; task.event carries taskId + type/status.
fn terminal_task_id(ev: &Value) -> Option<&str> {
    let p = ev.get("params")?;
    if let Some(t) = p.get("task") {
        let st = t.get("status").and_then(|s| s.as_str())?;
        if matches!(st, "completed" | "failed" | "cancelled") {
            return t.get("id").and_then(|i| i.as_str());
        }
        return None;
    }
    let ty = p.get("type").and_then(|s| s.as_str()).unwrap_or("");
    let st = p.get("status").and_then(|s| s.as_str()).unwrap_or("");
    if matches!(ty, "completed" | "failed")
        || matches!(st, "completed" | "failed" | "cancelled")
    {
        return p.get("taskId").and_then(|i| i.as_str());
    }
    None
}

// --------------------------------------------------------------------
// Command handlers
// --------------------------------------------------------------------

/// Headers pass-through (cookie/authorization come from the
/// extension's capture context) — names/values must be printable
/// header text: no CR/LF, no control chars, bounded length.
fn validated_headers(p: &Map<String, Value>) -> Result<Map<String, Value>, String> {
    let mut headers = Map::new();
    if let Some(h) = p.get("headers").and_then(|v| v.as_object()) {
        for (k, v) in h {
            let val = v.as_str().unwrap_or("");
            if k.len() > 128
                || val.len() > 8192
                || k.chars().any(|c| {
                    c.is_control() || c == ':' || c.is_whitespace()
                })
                || val.chars().any(|c| c.is_control() && c != '\t')
            {
                return Err("invalid header name/value".into());
            }
            headers.insert(k.clone(), json!(val));
        }
    }
    Ok(headers)
}

/// explorer.exe needs its switch args verbatim on the command
/// line — its hand-rolled parser splits on spaces even inside
/// Rust-quoted argv, so `cmd.arg("/select,C:\a b\f")` still breaks
/// and Explorer falls back to Documents. raw_arg emits the
/// documented `/select,"path"` form. Real paths can't contain a
/// quote char on Windows, so no escaping is needed.
#[cfg(windows)]
fn explorer_arg(cmd: &mut Command, raw: String) {
    use std::os::windows::process::CommandExt;
    cmd.raw_arg(raw);
}

#[cfg(not(windows))]
fn explorer_arg(cmd: &mut Command, raw: String) {
    cmd.arg(raw); // explorer.exe only exists on Windows anyway
}

fn task_id_of(payload: &Map<String, Value>) -> Result<String, String> {
    let id = payload
        .get("taskId")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    // task ids are ours (uuid-ish) — keep the charset tight so an id
    // can never be turned into a path or argument.
    if id.len() > 128
        || !id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("invalid taskId".into());
    }
    Ok(id.to_string())
}

fn handle(
    msg: &BrowserMessage,
    engine: &mut Option<EngineClient>,
    cfg: &mut Config,
    subs: &mut BTreeSet<String>,
) -> Result<Value, String> {
    match msg.command.as_str() {
        "ping" => {
            let engine_ok = match engine {
                Some(_) => engine_call(engine, "engine.hello", Map::new()).is_ok(),
                None => match ensure_engine(engine, cfg, subs) {
                    Ok(()) => engine_call(engine, "engine.hello", Map::new()).is_ok(),
                    Err(_) => false,
                },
            };
            Ok(json!({
                "ok": true,
                "protocol": PROTOCOL_VERSION,
                "engineReachable": engine_ok,
            }))
        }
        "pickFolder" => {
            // OS folder picker — the ONLY channel through which an
            // absolute target dir can enter the system. The returned
            // path is user consent, not browser input: a dir inside
            // downloadDir comes back as a plain subdir, anything
            // outside is recorded in pickedDirs and returned as an
            // absolute root the download command will accept.
            let root = cfg.download_dir.clone().unwrap_or_else(|| {
                env::var("USERPROFILE")
                    .map(|u| format!("{}\\Downloads", u))
                    .unwrap_or_else(|_| ".".into())
            });
            // FolderBrowserDialog needs STA; a borderless top-most
            // owner form keeps the picker in front of the browser.
            // OutputEncoding forces UTF-8 so non-ASCII paths
            // survive the console pipe.
            let script = concat!(
                "Add-Type -AssemblyName System.Windows.Forms;",
                "$f = New-Object System.Windows.Forms.Form;",
                "$f.TopMost = $true; $f.ShowInTaskbar = $false;",
                "$d = New-Object System.Windows.Forms.FolderBrowserDialog;",
                "$d.Description = 'Select download folder';",
                "$d.ShowNewFolderButton = $true;",
                "$d.SelectedPath = $env:JJAMIDM_PICK_ROOT;",
                "[Console]::OutputEncoding = [Text.Encoding]::UTF8;",
                "if ($d.ShowDialog($f) -eq 'OK') ",
                "{ [Console]::Out.Write($d.SelectedPath) }"
            );
            let out = std::process::Command::new("powershell.exe")
                .args(["-NoProfile", "-STA", "-Command", script])
                .env("JJAMIDM_PICK_ROOT", &root)
                .output()
                .map_err(|e| format!("folder picker: {}", e))?;
            let picked =
                String::from_utf8_lossy(&out.stdout).trim().to_string();
            if picked.is_empty() {
                return Ok(json!({"cancelled": true}));
            }
            // The picker can name a not-yet-created folder
            // (ShowNewFolderButton); materialize then canonicalize.
            std::fs::create_dir_all(&picked)
                .map_err(|e| format!("cannot create folder: {}", e))?;
            let canon = std::fs::canonicalize(&picked)
                .map_err(|e| format!("canonicalize: {}", e))?;
            let canon_base = std::fs::canonicalize(&root)
                .map_err(|_| "downloadDir not found".to_string())?;
            if let Ok(rel) = canon.strip_prefix(&canon_base) {
                return Ok(json!({
                    "subdir": rel.to_string_lossy().replace('/', "\\"),
                }));
            }
            let abs = deverbatim(&canon);
            persist_picked_dir(cfg, &abs);
            Ok(json!({"absDir": abs}))
        }
        "download" => {
            let p = &msg.payload;
            let url = p.get("url").and_then(|v| v.as_str()).unwrap_or("");
            validate_url(url)?;
            if let Some(f) = p.get("suggestedFilename").and_then(|v| v.as_str()) {
                validate_path_component(f)?;
            }
            for opt in ["referer", "pageUrl"] {
                if let Some(u) = p.get(opt).and_then(|v| v.as_str()) {
                    validate_url(u)?;
                }
            }
            let headers = validated_headers(p)?;

            // Resolve + validate the target dir BEFORE spawning the
            // engine — invalid input must fail before any side
            // effect (process spawn, task_id mint).
            let mut target_dir = cfg.download_dir.clone().unwrap_or_else(|| {
                env::var("USERPROFILE")
                    .map(|u| format!("{}\\Downloads", u))
                    .unwrap_or_else(|_| ".".into())
            });
            // absDir may only name a dir the user physically picked
            // in the OS folder dialog — anything else is an invented
            // path and is rejected.
            if let Some(abs) = p.get("absDir").and_then(|v| v.as_str()) {
                if abs.is_empty() || abs.len() > 1024
                    || abs.chars().any(|c| c.is_control())
                {
                    return Err("invalid absDir".into());
                }
                let canon = std::fs::canonicalize(abs)
                    .map_err(|_| "picked folder not found".to_string())?;
                // picked dirs are stored de-verbatimized — compare
                // like with like.
                let canon_s = deverbatim(&canon);
                let inside = cfg.picked_dirs.iter().any(|d| {
                    std::path::Path::new(&canon_s)
                        .starts_with(std::path::Path::new(d))
                });
                if !inside {
                    return Err("absDir was not user-picked".into());
                }
                target_dir = canon_s;
            }
            if let Some(sub) = p.get("subdir").and_then(|v| v.as_str()) {
                let rel = validate_subdir(sub)?;
                target_dir = format!("{}\\{}", target_dir, rel);
                std::fs::create_dir_all(&target_dir)
                    .map_err(|e| format!("cannot create subdir: {}", e))?;
            }

            ensure_engine(engine, cfg, subs)?;
            let task_id = format!("{:x}", std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0));

            let mut dto = Map::new();
            dto.insert("url".into(), json!(url));
            dto.insert("targetDirectory".into(), json!(target_dir));
            if let Some(f) = p.get("suggestedFilename").and_then(|v| v.as_str()) {
                dto.insert("fileName".into(), json!(f));
            }
            if let Some(r) = p.get("referer").and_then(|v| v.as_str()) {
                dto.insert("referer".into(), json!(r));
            }
            if let Some(ua) = p.get("userAgent").and_then(|v| v.as_str()) {
                dto.insert("userAgent".into(), json!(ua));
            }
            // Capture page → originalPageUrl — URL-refresh resolvers
            // re-fetch it when a signed link expires mid-download.
            if let Some(pu) = p.get("pageUrl").and_then(|v| v.as_str()) {
                dto.insert("pageUrl".into(), json!(pu));
            }
            if !headers.is_empty() {
                dto.insert("headers".into(), Value::Object(headers));
            }
            if let Some(mc) = p.get("maxConnections").and_then(|v| v.as_u64()) {
                dto.insert("maxConnections".into(), json!(mc.clamp(1, 16)));
            }
            let mut params = Map::new();
            params.insert("taskId".into(), json!(task_id));
            params.insert("request".into(), Value::Object(dto));
            if let Some(pr) = p.get("priority").and_then(|v| v.as_i64()) {
                params.insert("priority".into(), json!(pr));
            }
            // Any failure after task.create leaves a persisted
            // parked task behind — the extension then falls back to
            // a browser download and the orphaned queue entry can be
            // started later, producing a duplicate download. Compensate
            // with a best-effort task.cancel on a fresh engine.
            let created = engine_call(engine, "task.create", params);
            if let Err(err) = created {
                compensate_created(engine, cfg, subs, &task_id);
                return Err(err);
            }
            // Subscribe BEFORE start — a small file can finish in
            // the gap and its terminal event would be lost.
            let mut sub = Map::new();
            sub.insert("taskId".into(), json!(task_id));
            if let Err(err) = engine_call(engine, "task.subscribeEvents", sub) {
                compensate_created(engine, cfg, subs, &task_id);
                return Err(err);
            }
            // Track it — an engine respawn loses this subscription
            // and ensure_engine replays it.
            subs.insert(task_id.clone());
            // start:false parks the task in the scheduler queue —
            // a later `start` command admits it.
            let start = p.get("start").and_then(|v| v.as_bool()).unwrap_or(true);
            if start {
                let mut sp = Map::new();
                sp.insert("taskId".into(), json!(task_id));
                if let Err(err) = engine_call(engine, "task.start", sp) {
                    compensate_created(engine, cfg, subs, &task_id);
                    return Err(err);
                }
            }
            Ok(json!({"taskId": task_id}))
        }
        "media" => {
            // Media page → host-side media pipeline (yt-dlp + FFmpeg
            // live inside engine-host; browser never picks paths).
            let p = &msg.payload;
            let url = p
                .get("pageUrl")
                .or_else(|| p.get("url"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            validate_url(url)?;
            let headers = validated_headers(&msg.payload)?;
            ensure_engine(engine, cfg, subs)?;
            let mut params = Map::new();
            params.insert("pageUrl".into(), json!(url));
            if !headers.is_empty() {
                params.insert("headers".into(), Value::Object(headers));
            }
            params.insert(
                "targetDirectory".into(),
                json!(cfg.download_dir.clone().unwrap_or_else(|| {
                    env::var("USERPROFILE")
                        .map(|u| format!("{}\\Downloads", u))
                        .unwrap_or_else(|_| ".".into())
                })),
            );
            let r = engine_call(engine, "media.enqueue", params)?;
            Ok(json!({
                "taskId": r.get("taskId").cloned().unwrap_or(Value::Null),
            }))
        }
        "start" | "pause" | "resume" | "cancel" => {
            let id = task_id_of(&msg.payload)?;
            // Cold-launch on demand: queue-persisted tasks survive a
            // host restart, so control commands must reach the engine
            // even when this is the first message after boot.
            ensure_engine(engine, cfg, subs)?;
            // A respawned engine lost every subscription — replay
            // covered only ids in `subs`. A persisted task (parked
            // before the restart, or simply never subscribed this
            // session) started/resumed now would run with no events
            // reaching the browser. Re-subscribe first; unknown ids
            // fail subscribeEvents, which is fine — the command
            // itself reports the real error.
            let mut sp = Map::new();
            sp.insert("taskId".into(), json!(id));
            if engine_call(engine, "task.subscribeEvents", sp).is_ok() {
                subs.insert(id.clone());
            }
            let method = format!("task.{}", msg.command);
            let mut p = Map::new();
            p.insert("taskId".into(), json!(id));
            match engine_call(engine, &method, p) {
                Ok(v) => v,
                Err(err) => {
                    // media tasks live in the coordinator — task.*
                    // does not know them; fall back to media.<cmd>.
                    // `start` has no media counterpart (media tasks
                    // always run), and a transport failure already
                    // dropped the engine — don't retry a dead pipe.
                    if msg.command == "start" || engine.is_none() {
                        return Err(err);
                    }
                    let mut mp = Map::new();
                    mp.insert("taskId".into(), json!(id));
                    engine_call(engine, &format!("media.{}", msg.command), mp)
                        .map_err(|_| err)?
                }
            };
            Ok(json!({"ok": true}))
        }
        "status" => {
            let id = task_id_of(&msg.payload)?;
            ensure_engine(engine, cfg, subs)?;
            let mut p = Map::new();
            p.insert("taskId".into(), json!(id));
            engine_call(engine, "task.status", p)
        }
        "reveal" | "open" => {
            // Open/reveal a completed download in Explorer. The path
            // comes from the extension (it saw outputPath in the
            // completed event) but must resolve inside download_dir —
            // an extension can never open arbitrary paths.
            let raw = msg
                .payload
                .get("path")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if raw.is_empty()
                || raw.len() > 1024
                || raw.chars().any(|c| c.is_control())
            {
                return Err("invalid path".into());
            }
            let base = cfg.download_dir.clone().ok_or("downloadDir unset")?;
            let canon_base = std::fs::canonicalize(&base)
                .map_err(|_| "downloadDir not found".to_string())?;
            let canon_path = std::fs::canonicalize(raw)
                .map_err(|_| "path not found".to_string())?;
            // Files the user chose to save outside downloadDir (via
            // the OS picker) stay openable — picked_dirs are the
            // only other allowed roots. picked_dirs are stored
            // de-verbatimized, so compare like with like.
            let canon_s = deverbatim(&canon_path);
            if !canon_path.starts_with(&canon_base)
                && !cfg
                    .picked_dirs
                    .iter()
                    .any(|d| std::path::Path::new(&canon_s)
                        .starts_with(std::path::Path::new(d)))
            {
                return Err("path outside downloadDir".into());
            }
            // canonicalize yields \\?\ verbatim paths — explorer.exe
            // does not understand them, so strip the prefix.
            let disp = deverbatim(&canon_path);
            let mut cmd = std::process::Command::new("explorer.exe");
            if msg.command == "reveal" {
                // explorer's /select parser is hand-rolled and
                // tokenizes on spaces even inside quoted argv —
                // a spaced path falls back to Documents. Emit the
                // documented form verbatim: /select,"C:\a b\f"
                explorer_arg(&mut cmd, format!("/select,\"{}\"", disp));
            } else {
                explorer_arg(&mut cmd, format!("\"{}\"", disp));
            }
            cmd.spawn().map_err(|e| format!("explorer: {}", e))?;
            Ok(json!({"ok": true}))
        }
        other => Err(format!("command not allowed: {}", other)),
    }
}

fn respond(msg: &BrowserMessage, result: Result<Value, String>) -> Value {
    match result {
        Ok(v) => json!({
            "protocol": PROTOCOL_VERSION,
            "requestId": msg.request_id,
            "ok": true,
            "result": v,
        }),
        Err(e) => json!({
            "protocol": PROTOCOL_VERSION,
            "requestId": msg.request_id,
            "ok": false,
            "error": e,
        }),
    }
}

fn write_frame(out: &mut impl Write, v: &Value) -> io::Result<()> {
    let body = serde_json::to_vec(v)?;
    if body.len() as u32 > MAX_MESSAGE_BYTES {
        let body = serde_json::to_vec(&json!({
            "protocol": PROTOCOL_VERSION, "ok": false,
            "error": "response too large",
        }))?;
        out.write_all(&(body.len() as u32).to_le_bytes())?;
        return out.write_all(&body);
    }
    out.write_all(&(body.len() as u32).to_le_bytes())?;
    out.write_all(&body)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut cfg = load_config();

    // --self-test bypasses the origin check for local dev/CI only;
    // browsers always pass the extension origin as argv[1].
    let self_test = args.iter().any(|a| a == "--self-test");
    if !self_test {
        if let Err(e) = check_origin(&args, &cfg) {
            let mut out = io::stdout();
            let _ = write_frame(&mut out, &json!({
                "protocol": PROTOCOL_VERSION, "ok": false, "error": e,
            }));
            let _ = out.flush();
            std::process::exit(2);
        }
    }

    // Chrome and Edge each spawn their OWN host process against the
    // same config — a shared queue dir means the second engine's
    // queue lock acquisition fails and every download on that
    // browser dies with a spawn error. Key the queue by the calling
    // origin so each browser owns an isolated queue (parked tasks
    // stay with the browser that created them anyway).
    if !self_test {
        if let (Some(q), Some(origin)) = (&cfg.queue_dir, args.get(1)) {
            let tag: String = origin
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
                .collect();
            cfg.queue_dir = Some(format!("{}\\{}", q, tag));
        }
    }

    // Reader thread: frames in; the main loop owns all writes so
    // engine task events can stream to the browser even while stdin
    // is idle.
    let (msg_tx, msg_rx) = mpsc::channel::<Result<BrowserMessage, String>>();
    thread::spawn(move || {
        let mut input = io::stdin();
        loop {
            let mut len_buf = [0u8; 4];
            if input.read_exact(&mut len_buf).is_err() {
                break; // browser closed the pipe
            }
            let len = u32::from_le_bytes(len_buf);
            if len == 0 || len > MAX_MESSAGE_BYTES {
                let _ = msg_tx.send(Err("frame too large".into()));
                break; // hard cap — drop the channel on abuse
            }
            let mut body = vec![0u8; len as usize];
            if input.read_exact(&mut body).is_err() {
                break;
            }
            let parsed = serde_json::from_slice::<BrowserMessage>(&body)
                .map_err(|_| "malformed message".to_string());
            if msg_tx.send(parsed).is_err() {
                break;
            }
        }
        // EOF / fatal → tell the main loop to exit.
        let _ = msg_tx.send(Err("__eof__".into()));
    });

    let mut output = io::stdout();
    let mut engine: Option<EngineClient> = None;
    // Task ids with a live task.subscribeEvents — replayed on every
    // engine respawn, pruned when a terminal event arrives.
    let mut subscribed: BTreeSet<String> = BTreeSet::new();

    'main: loop {
        // Stream any pending engine task events to the browser.
        if let Some(e) = engine.as_ref() {
            while let Ok(ev) = e.pending_events.try_recv() {
                if let Some(id) = terminal_task_id(&ev) {
                    subscribed.remove(id);
                }
                if write_frame(&mut output, &json!({
                    "protocol": PROTOCOL_VERSION,
                    "type": "taskEvent",
                    "event": ev,
                }))
                .is_err()
                {
                    break 'main;
                }
            }
            let _ = output.flush();
        }

        match msg_rx.recv_timeout(std::time::Duration::from_millis(100)) {
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(_) => break,
            Ok(Err(e)) if e == "__eof__" => break,
            Ok(Err(e)) => {
                let _ = write_frame(&mut output, &json!({
                    "protocol": PROTOCOL_VERSION, "requestId": Value::Null,
                    "ok": false, "error": e,
                }));
                let _ = output.flush();
            }
            Ok(Ok(msg)) => {
                let reply = if msg.protocol != PROTOCOL_VERSION {
                    respond(&msg, Err("unsupported protocol version".into()))
                } else if msg.source.as_deref() != Some("extension")
                    || msg.extension_version.is_none()
                {
                    respond(&msg, Err(
                        "missing source/extensionVersion".into()))
                } else if !ALLOWED_COMMANDS.contains(&msg.command.as_str()) {
                    respond(&msg, Err(format!(
                        "command not allowed: {}", msg.command)))
                } else {
                    respond(&msg, handle(&msg, &mut engine, &mut cfg, &mut subscribed))
                };
                if write_frame(&mut output, &reply).is_err() {
                    break;
                }
                let _ = output.flush();
            }
        }
    }
}
