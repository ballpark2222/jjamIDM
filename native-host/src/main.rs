//! FreeDM native messaging host (Browser Protocol v1).
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
    "pause",
    "resume",
    "cancel",
    "status",
    "list",
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
}

fn load_config() -> Config {
    // %APPDATA%\FreeDM\native-host.json (or FREEDM_NATIVE_HOST_CONFIG)
    let path = env::var("FREEDM_NATIVE_HOST_CONFIG").ok().or_else(|| {
        env::var("APPDATA")
            .ok()
            .map(|d| format!("{}\\FreeDM\\native-host.json", d))
    });
    let mut cfg = Config {
        allowed_origins: vec![],
        engine_command: vec![],
        engine_cwd: None,
        download_dir: None,
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
    cmd.args(&cfg.engine_command[1..])
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
                                    if v.get("method").and_then(|m| m.as_str())
                                        == Some("task.event")
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

// --------------------------------------------------------------------
// Command handlers
// --------------------------------------------------------------------

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
    cfg: &Config,
) -> Result<Value, String> {
    match msg.command.as_str() {
        "ping" => {
            let engine_ok = match engine {
                Some(e) => e.call("engine.hello", Map::new()).is_ok(),
                None => match spawn_engine(cfg) {
                    Ok(mut e) => {
                        let ok = e.call("engine.hello", Map::new()).is_ok();
                        *engine = Some(e);
                        ok
                    }
                    Err(_) => false,
                },
            };
            Ok(json!({
                "ok": true,
                "protocol": PROTOCOL_VERSION,
                "engineReachable": engine_ok,
            }))
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
            // headers pass-through (cookie/authorization come from the
            // extension's capture context) — names/values must be
            // printable header text: no CR/LF, no control chars.
            let mut headers = Map::new();
            if let Some(h) = p.get("headers").and_then(|v| v.as_object()) {
                for (k, v) in h {
                    let val = v.as_str().unwrap_or("");
                    if k.len() > 128
                        || val.len() > 8192
                        || k.chars().any(|c| {
                            c.is_control() || c == ':' || c.is_whitespace()
                        })
                        || val.chars().any(|c| {
                            c.is_control() && c != '\t'
                        })
                    {
                        return Err("invalid header name/value".into());
                    }
                    headers.insert(k.clone(), json!(val));
                }
            }
            if engine.is_none() {
                *engine = Some(spawn_engine(cfg)?);
            }
            let e = engine.as_mut().unwrap();

            let task_id = format!("{:x}", std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0));

            let mut dto = Map::new();
            dto.insert("url".into(), json!(url));
            dto.insert(
                "targetDirectory".into(),
                json!(cfg.download_dir.clone().unwrap_or_else(|| {
                    env::var("USERPROFILE")
                        .map(|u| format!("{}\\Downloads", u))
                        .unwrap_or_else(|_| ".".into())
                })),
            );
            if let Some(f) = p.get("suggestedFilename").and_then(|v| v.as_str()) {
                dto.insert("fileName".into(), json!(f));
            }
            if let Some(r) = p.get("referer").and_then(|v| v.as_str()) {
                dto.insert("referer".into(), json!(r));
            }
            if let Some(ua) = p.get("userAgent").and_then(|v| v.as_str()) {
                dto.insert("userAgent".into(), json!(ua));
            }
            if !headers.is_empty() {
                dto.insert("headers".into(), Value::Object(headers));
            }
            let mut params = Map::new();
            params.insert("taskId".into(), json!(task_id));
            params.insert("request".into(), Value::Object(dto));
            e.call("task.create", params)?;
            let mut sp = Map::new();
            sp.insert("taskId".into(), json!(task_id));
            e.call("task.start", sp)?;
            let mut sub = Map::new();
            sub.insert("taskId".into(), json!(task_id));
            e.call("task.subscribeEvents", sub)?;
            Ok(json!({"taskId": task_id}))
        }
        "pause" | "resume" | "cancel" => {
            let id = task_id_of(&msg.payload)?;
            let e = engine.as_mut().ok_or("engine not running")?;
            let method = format!("task.{}", msg.command);
            let mut p = Map::new();
            p.insert("taskId".into(), json!(id));
            e.call(&method, p)?;
            Ok(json!({"ok": true}))
        }
        "status" => {
            let id = task_id_of(&msg.payload)?;
            let e = engine.as_mut().ok_or("engine not running")?;
            let mut p = Map::new();
            p.insert("taskId".into(), json!(id));
            e.call("task.status", p)
        }
        "list" => Ok(json!({"tasks": []})), // populated once repo IPC lands
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
    let cfg = load_config();

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

    'main: loop {
        // Stream any pending engine task events to the browser.
        if let Some(e) = engine.as_ref() {
            while let Ok(ev) = e.pending_events.try_recv() {
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
                    respond(&msg, handle(&msg, &mut engine, &cfg))
                };
                if write_frame(&mut output, &reply).is_err() {
                    break;
                }
                let _ = output.flush();
            }
        }
    }
}
