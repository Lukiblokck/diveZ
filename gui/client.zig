//! Client for the running divez daemon (loopback HTTP API). No UI code here.
const std = @import("std");
const posix = std.posix;
const config = @import("config");

/// The daemon's persisted settings, as reported in /api/status and accepted by /api/config.
/// Empty strings mean "use the default"; `serial` is "auto" or a /dev path.
pub const Settings = struct {
    serial: []const u8 = "auto",
    prefix: []const u8 = "",
    exe: []const u8 = "",
    capture_dir: []const u8 = "",
    autolaunch: bool = true,
};

/// Subset of GET /api/status the window shows; unknown fields are ignored.
pub const Status = struct {
    version: []const u8 = "",
    serial_online: bool = false,
    serial_path: []const u8 = "",
    serial_error: []const u8 = "",
    wine_found: bool = false,
    prefix_ready: bool = false,
    exe: []const u8 = "",
    diver_running: bool = false,
    to_device: u64 = 0,
    from_device: u64 = 0,
    capture_dir: []const u8 = "",
    settings: Settings = .{},
};

/// GET /api/detect: what the daemon found on this machine.
pub const Detected = struct {
    serials: []const []const u8 = &.{},
    exes: []const []const u8 = &.{},
};
pub const DetectSnapshot = std.json.Parsed(Detected);

/// Reply of POST /api/config. `reason` names the rejected field when `ok` is false
/// ("invalid serial", ...); `saved` is false when the file could not be written.
pub const ConfigResult = struct {
    ok: bool = false,
    reason: []const u8 = "",
    saved: bool = true,
    restart_required: bool = false,
};
pub const ConfigOutcome = std.json.Parsed(ConfigResult);

/// Owns the memory behind the strings in `value`; call `deinit` when done.
pub const Snapshot = std.json.Parsed(Status);

/// Why a request failed, from the user's point of view.
pub const Error = error{
    /// No diveZ process: safe to start one.
    DaemonNotRunning,
    /// A diveZ process is alive but its address file is missing or nothing answers there.
    DaemonUnreachable,
    Timeout,
    /// The connection broke in the middle of the exchange.
    ConnectionLost,
    /// HTTP 403: the access key in the address file is not the one the daemon expects.
    Unauthorized,
    BadResponse,
};

// Per-operation socket timeouts. Everything runs off the UI thread, and the machine may be old
// and busy, so be generous: a false "not answering" is worse than a short wait.
const poll_timeout_ms: u32 = 1500; // reads
const action_timeout_ms: u32 = 3000; // launch, save, quit
const max_response = 64 * 1024;

const Endpoint = struct { port: u16, token: []const u8 };

/// `url` looks like `http://127.0.0.1:PORT/?t=TOKEN` (the daemon's url file).
fn parseUrl(url: []const u8) ?Endpoint {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const port = std.fmt.parseInt(u16, rest[0..slash], 10) catch return null;
    const marker = "?t=";
    const at = std.mem.indexOf(u8, rest, marker) orelse return null;
    const token = rest[at + marker.len ..];
    if (token.len == 0) return null;
    return .{ .port = port, .token = token };
}

/// POST endpoints the window can trigger (all exist in the daemon's route table).
pub const Action = enum {
    launch,
    open_captures,
    quit,

    fn path(self: Action) []const u8 {
        return switch (self) {
            .launch => "/api/launch",
            .open_captures => "/api/open-captures",
            .quit => "/api/quit",
        };
    }
};

/// Reply of a POST action. `reason` is the daemon's error name when `ok` is false.
pub const ActionResult = struct {
    ok: bool = false,
    reason: []const u8 = "",
};
pub const Outcome = std.json.Parsed(ActionResult);

/// Blocking (call from the worker), bounded per socket operation.
pub fn fetchStatus(allocator: std.mem.Allocator) (Error || std.mem.Allocator.Error)!Snapshot {
    return requestJson(Status, allocator, "GET", "/api/status", null, false, poll_timeout_ms);
}

/// Blocking (call from the worker), bounded per socket operation.
pub fn fetchDetect(allocator: std.mem.Allocator) (Error || std.mem.Allocator.Error)!DetectSnapshot {
    return requestJson(Detected, allocator, "GET", "/api/detect", null, false, poll_timeout_ms);
}

/// JSON body of POST /api/config for these settings. Caller frees.
pub fn configBody(allocator: std.mem.Allocator, settings: Settings) std.mem.Allocator.Error![]u8 {
    return std.json.stringifyAlloc(allocator, settings, .{});
}

/// Send a body made by `configBody`. A rejected field comes back as `ok = false`
/// (HTTP 400), not as an error.
pub fn saveConfigBody(allocator: std.mem.Allocator, body: []const u8) (Error || std.mem.Allocator.Error)!ConfigOutcome {
    return requestJson(ConfigResult, allocator, "POST", "/api/config", body, true, action_timeout_ms);
}

/// Blocking (call from the worker), bounded per socket operation.
pub fn runAction(allocator: std.mem.Allocator, action: Action) (Error || std.mem.Allocator.Error)!Outcome {
    return requestJson(ActionResult, allocator, "POST", action.path(), null, false, action_timeout_ms);
}

const Connected = struct { stream: std.net.Stream, ep: Endpoint };

/// Find the daemon's address and connect. Every candidate directory is tried, so a window that
/// does not share the daemon's environment still finds it. `url_buf` keeps the token alive.
fn connect(url_buf: []u8) Error!Connected {
    var rd: config.RunDirs = .{};
    config.runDirs(&rd);
    for (rd.slice()) |dir| {
        const url = config.readUrlFileIn(dir, url_buf) orelse continue;
        const ep = parseUrl(url) orelse continue;
        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ep.port);
        const stream = std.net.tcpConnectToAddress(addr) catch continue;
        return .{ .stream = stream, .ep = ep };
    }
    // Nothing answered. A diveZ process that is alive but not reachable needs a different
    // remedy (restart it) than no process at all (start it).
    return if (config.findDaemonPid() != null) error.DaemonUnreachable else error.DaemonNotRunning;
}

/// One transient failure on a read is retried once (the daemon serves one connection per tick).
fn requestJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    accept_400: bool,
    timeout_ms: u32,
) (Error || std.mem.Allocator.Error)!std.json.Parsed(T) {
    return requestOnce(T, allocator, method, path, body, accept_400, timeout_ms) catch |err| {
        const retry = std.mem.eql(u8, method, "GET") and (err == error.ConnectionLost or err == error.Unauthorized);
        if (!retry) return err;
        std.time.sleep(150 * std.time.ns_per_ms); // a restarted daemon has a new address file by now
        return requestOnce(T, allocator, method, path, body, accept_400, timeout_ms);
    };
}

fn requestOnce(
    comptime T: type,
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    accept_400: bool,
    timeout_ms: u32,
) (Error || std.mem.Allocator.Error)!std.json.Parsed(T) {
    var url_buf: [512]u8 = undefined;
    const conn = try connect(&url_buf);
    const stream = conn.stream;
    const ep = conn.ep;
    defer stream.close();

    const tv = posix.timeval{ .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
    posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch return error.ConnectionLost;
    posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch return error.ConnectionLost;

    // POST must carry the token in the header (the daemon never reads it from the query).
    // The daemon reads at most 8 KB per request; settings bodies are well below that.
    const payload = body orelse "";
    const req = std.fmt.allocPrint(
        allocator,
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nX-DiveZ-Token: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ method, path, ep.port, ep.token, payload.len, payload },
    ) catch return error.OutOfMemory;
    defer allocator.free(req);
    stream.writeAll(req) catch |err| return mapIo(err);

    const raw = stream.reader().readAllAlloc(allocator, max_response) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return mapIo(err),
    };
    defer allocator.free(raw);

    if (raw.len == 0) return error.ConnectionLost; // closed without answering
    if (std.mem.startsWith(u8, raw, "HTTP/1.1 403")) return error.Unauthorized;
    const status_ok = std.mem.startsWith(u8, raw, "HTTP/1.1 200") or
        (accept_400 and std.mem.startsWith(u8, raw, "HTTP/1.1 400"));
    if (!status_ok) return error.BadResponse;
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    // `raw` is freed on return, so the parsed strings must be copies (alloc_always).
    return std.json.parseFromSlice(T, allocator, raw[split + 4 ..], .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadResponse,
    };
}

/// A timeout is a timeout; any other socket failure means the connection broke. (Calling
/// everything "not running" made a busy daemon look dead.)
fn mapIo(err: anyerror) Error {
    return switch (err) {
        error.WouldBlock => error.Timeout,
        else => error.ConnectionLost,
    };
}

/// One line for the user to read out when asking for help: where the window looked and what it
/// found. Runs on the UI thread; only reads a few small files.
pub fn diagnose(buf: []u8) []const u8 {
    var rd: config.RunDirs = .{};
    config.runDirs(&rd);
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("Looked in:") catch return fbs.getWritten();
    for (rd.slice(), 0..) |dir, k| w.print("{s} {s}", .{ if (k == 0) "" else ",", dir }) catch return fbs.getWritten();
    var ub: [512]u8 = undefined;
    var port: ?u16 = null;
    for (rd.slice()) |dir| {
        if (config.readUrlFileIn(dir, &ub)) |u| {
            if (parseUrl(u)) |ep| {
                port = ep.port;
                break;
            }
        }
    }
    if (port) |p| w.print(". Address file: port {d}", .{p}) catch return fbs.getWritten() else w.writeAll(". Address file: none") catch return fbs.getWritten();
    if (config.findDaemonPid()) |pid| w.print(". Process: running (pid {d}).", .{pid}) catch return fbs.getWritten() else w.writeAll(". Process: not found.") catch return fbs.getWritten();
    return fbs.getWritten();
}

pub const StartError = error{
    /// No `divez` next to this program, in ~/.local/bin or in the PATH.
    ProgramNotFound,
    StartFailed,
};

/// Where the daemon program is, if it can be found by path: next to this program, or in
/// ~/.local/bin (where the installer puts it). Null means "let the PATH decide".
fn findDaemonExe(buf: []u8) ?[]const u8 {
    var dirbuf: [posix.PATH_MAX]u8 = undefined;
    if (std.fs.selfExeDirPath(&dirbuf)) |dir| {
        if (std.fmt.bufPrint(buf, "{s}/divez", .{dir})) |p| {
            if (isExecutable(p)) return p;
        } else |_| {}
    } else |_| {}
    if (config.homeDir()) |home| {
        if (std.fmt.bufPrint(buf, "{s}/.local/bin/divez", .{home})) |p| {
            if (isExecutable(p)) return p;
        } else |_| {}
    } else |_| {}
    return null;
}

fn isExecutable(path: []const u8) bool {
    var pb: [posix.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintZ(&pb, "{s}", .{path}) catch return false;
    posix.accessZ(z, posix.X_OK) catch return false;
    return true;
}

/// Start the daemon in the background (it detaches itself and quits after 15 idle minutes).
/// Returns once the launcher process has returned, not once the daemon is reachable.
pub fn startDaemon(allocator: std.mem.Allocator) StartError!void {
    var exe_buf: [posix.PATH_MAX]u8 = undefined;
    const exe = findDaemonExe(&exe_buf) orelse "divez";
    return runAndWait(allocator, &.{ exe, "--service", "--detach", "--idle-exit" });
}

/// Run a program with its output discarded and wait for it. Zig 0.13 reports a program that
/// cannot be executed from `wait`, not from `spawn`, so both are mapped.
fn runAndWait(allocator: std.mem.Allocator, argv: []const []const u8) StartError!void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| return startError(err);
    const term = child.wait() catch |err| return startError(err);
    switch (term) {
        .Exited => |code| if (code != 0) return error.StartFailed,
        else => return error.StartFailed,
    }
}

fn startError(err: anyerror) StartError {
    return if (err == error.FileNotFound) error.ProgramNotFound else error.StartFailed;
}

/// Ask a running daemon to quit (SIGTERM) and wait for it to be gone. True when none is left.
pub fn stopDaemon() bool {
    const pid = config.findDaemonPid() orelse return true;
    posix.kill(pid, posix.SIG.TERM) catch return false;
    const deadline = std.time.milliTimestamp() + 4000;
    while (config.processIsDiveZ(pid)) {
        if (std.time.milliTimestamp() >= deadline) return false;
        std.time.sleep(50 * std.time.ns_per_ms);
    }
    return true;
}

test "parseUrl" {
    const ep = parseUrl("http://127.0.0.1:41235/?t=abcdef").?;
    try std.testing.expectEqual(@as(u16, 41235), ep.port);
    try std.testing.expectEqualStrings("abcdef", ep.token);
    try std.testing.expect(parseUrl("http://evil.example:80/?t=x") == null);
    try std.testing.expect(parseUrl("http://127.0.0.1:80/") == null);
}

test "status strings outlive the response buffer" {
    const a = std.testing.allocator;
    const raw = try a.dupe(u8, "{\"version\":\"0.2.0\",\"serial_path\":\"/dev/ttyUSB0\",\"extra\":1}");
    var parsed = try std.json.parseFromSlice(Status, a, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    a.free(raw);
    try std.testing.expectEqualStrings("0.2.0", parsed.value.version);
    try std.testing.expectEqualStrings("/dev/ttyUSB0", parsed.value.serial_path);
}

test "status carries the persisted settings" {
    const a = std.testing.allocator;
    const raw = "{\"version\":\"0.2.0\",\"settings\":{\"serial\":\"auto\",\"prefix\":\"/w\",\"exe\":\"\",\"capture_dir\":\"/c\",\"autolaunch\":false}}";
    var parsed = try std.json.parseFromSlice(Status, a, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/w", parsed.value.settings.prefix);
    try std.testing.expectEqualStrings("/c", parsed.value.settings.capture_dir);
    try std.testing.expect(!parsed.value.settings.autolaunch);
}

test "settings body is plain JSON" {
    const a = std.testing.allocator;
    const body = try configBody(a, Settings{ .prefix = "/w" });
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"serial\":\"auto\",\"prefix\":\"/w\",\"exe\":\"\",\"capture_dir\":\"\",\"autolaunch\":true}", body);
}

test "diagnose always says something" {
    var buf: [400]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, diagnose(&buf), "Looked in:"));
    var tiny: [8]u8 = undefined;
    _ = diagnose(&tiny); // a full buffer must not crash
}

test "a program that does not exist is reported as not found" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.ProgramNotFound, runAndWait(a, &.{"divez-no-such-program-xyz"}));
    try std.testing.expectError(error.ProgramNotFound, runAndWait(a, &.{"/nonexistent/dir/divez"}));
}

test "a program that runs and exits cleanly is a success; a failing one is not" {
    const a = std.testing.allocator;
    try runAndWait(a, &.{"true"});
    try std.testing.expectError(error.StartFailed, runAndWait(a, &.{"false"}));
}
