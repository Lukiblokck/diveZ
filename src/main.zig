//! diveZ: use Diver-Office (Wine) with a physical Diver USB reading unit.
//!
//! Normal use is just `divez` (or the desktop icon): everything is detected
//! automatically, a virtual COM port is published for Wine, Diver-Office is
//! started, and diveZ exits when Diver-Office exits. A small localhost web page
//! (opened only when something needs attention, or on demand) shows status and
//! lets non-technical users fix settings. Idle cost: one process, a few MB.
//!
//!   divez               auto-detect, bridge, launch Diver-Office
//!   divez --ui          open the status / settings page
//!   divez --service     headless daemon for init systems (no launch, no UI)
//!   divez -- cmd ...    bridge and supervise an arbitrary command (advanced)

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const term = @import("term.zig");
const tap_mod = @import("tap.zig");
const config = @import("config.zig");
const web = @import("web.zig");

const ui_html = @embedFile("ui.html");
const c = term.c;
const log = std.log.scoped(.divez);

pub const std_options: std.Options = .{ .log_level = .debug };

const poll_interval_ms = 250;
const reopen_interval_ms = 1000;
const link_retry_ms = 2000;
const device_write_timeout_ms = 2000;
const pty_write_timeout_ms = 50; // never let a dead Wine side stall the device side
const io_buf_size = 4096;
const idle_exit_ms = 15 * 60 * 1000;

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

const Mode = enum { app, ui, service, exec };

const Cli = struct {
    mode: Mode = .app,
    serial: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    link: ?[]const u8 = null,
    capture_dir: ?[]const u8 = null,
    baud: u32 = 9600,
    mirror: bool = true,
    assert_dtr_rts: bool = true,
    /// Fork into the background (new session, no terminal) so a launcher can return at once.
    detach: bool = false,
    /// Also exit after `idle_exit_ms` unused when running as --service (app/ui always do).
    idle_exit: bool = false,
    verbose: bool = false,
    exec_argv: []const [:0]u8 = &.{},
};

fn usage() void {
    std.debug.print(
        \\diveZ {s}
        \\usage: divez [options] [-- command args...]
        \\  (no options)          detect everything, bridge, start Diver-Office
        \\  --ui                  open the status / settings page
        \\  --service             headless daemon (for init systems)
        \\  --detach              run in the background, log to ~/diveZ/divez.log
        \\  --idle-exit           quit after 15 minutes unused (with --service)
        \\  --serial <path|auto>  USB serial device (default: auto)
        \\  --prefix <dir>        Wine prefix (default: $WINEPREFIX or ~/.wine)
        \\  --link <path>         explicit COM symlink path (default: <prefix>/dosdevices/com9)
        \\  --capture-dir <dir>   where captures go (default: ~/diveZ/captures)
        \\  --baud <n>            initial baud 1200..115200 (default 9600; Wine's setting wins)
        \\  --no-mirror           ignore Wine's line settings
        \\  --no-dtr-rts          do not assert DTR/RTS on the physical port
        \\  -v, --verbose         hex-dump all traffic
        \\  -- command ...        supervise a command instead of Diver-Office
        \\
    , .{config.version});
}

fn argValue(args: []const [:0]u8, i: usize) ![:0]const u8 {
    if (i >= args.len) return error.MissingValue;
    return args[i];
}

fn parseArgs(args: []const [:0]u8) !Cli {
    var cli = Cli{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--")) {
            cli.mode = .exec;
            cli.exec_argv = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, a, "--ui")) {
            cli.mode = .ui;
        } else if (std.mem.eql(u8, a, "--service")) {
            cli.mode = .service;
        } else if (std.mem.eql(u8, a, "--detach")) {
            cli.detach = true;
        } else if (std.mem.eql(u8, a, "--idle-exit")) {
            cli.idle_exit = true;
        } else if (std.mem.eql(u8, a, "--serial")) {
            i += 1;
            cli.serial = try argValue(args, i);
        } else if (std.mem.eql(u8, a, "--prefix")) {
            i += 1;
            cli.prefix = try argValue(args, i);
        } else if (std.mem.eql(u8, a, "--link")) {
            i += 1;
            cli.link = try argValue(args, i);
        } else if (std.mem.eql(u8, a, "--capture-dir")) {
            i += 1;
            cli.capture_dir = try argValue(args, i);
        } else if (std.mem.eql(u8, a, "--baud")) {
            i += 1;
            cli.baud = try std.fmt.parseInt(u32, try argValue(args, i), 10);
        } else if (std.mem.eql(u8, a, "--no-mirror")) {
            cli.mirror = false;
        } else if (std.mem.eql(u8, a, "--no-dtr-rts")) {
            cli.assert_dtr_rts = false;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            cli.verbose = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("diveZ {s}\n", .{config.version});
            std.process.exit(0);
        } else {
            log.err("unknown argument: {s}", .{a});
            return error.UnknownArgument;
        }
    }
    if (cli.mode == .exec and cli.exec_argv.len == 0) return error.MissingCommand;
    return cli;
}

// ---------------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------------

var shutdown_requested = std.atomic.Value(bool).init(false);

// NOTE: on Zig master use `callconv(.c)` instead of `callconv(.C)`.
fn onSignal(_: c_int) callconv(.C) void {
    shutdown_requested.store(true, .release);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn openUrl(a: std.mem.Allocator, target: []const u8) void {
    var child = std.process.Child.init(&[_][]const u8{ "xdg-open", target }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        log.warn("cannot run xdg-open; open this address in a browser: {s}", .{target});
    };
}

fn wineBinary(buf: []u8) ?[]const u8 {
    const name = posix.getenv("DIVEZ_WINE") orelse "wine";
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    return config.findInPath(name, buf);
}

/// (Re)create `link` -> `target`. Refuses to touch anything that is not a symlink.
fn publishLink(link: []const u8, target: []const u8) !void {
    var buf: [posix.PATH_MAX]u8 = undefined;
    if (std.fs.cwd().readLink(link, &buf)) |_| {
        try posix.unlink(link);
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.NotLink => {
            log.err("{s} exists and is not a symlink; refusing to overwrite", .{link});
            return error.LinkPathOccupied;
        },
        else => return err,
    }
    try posix.symlink(target, link);
}

fn jsonBody(a: std.mem.Allocator, res: *web.Response, value: anytype) !void {
    var list = std.ArrayList(u8).init(a);
    try std.json.stringify(value, .{}, list.writer());
    res.body = list.items;
}

fn fail(a: std.mem.Allocator, res: *web.Response, status: u16, reason: []const u8) void {
    res.status = status;
    res.body = std.fmt.allocPrint(a, "{{\"ok\":false,\"reason\":\"{s}\"}}", .{reason}) catch "{}";
}

// ---------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------

const Stats = struct {
    host_to_device: u64 = 0,
    device_to_host: u64 = 0,
    dropped_to_device: u64 = 0,
    dropped_to_host: u64 = 0,
    reconnects: u64 = 0,
};

const LaunchError = error{ AlreadyRunning, WineNotFound, ExeNotFound, SpawnFailed };

const Bridge = struct {
    gpa: std.mem.Allocator,
    cli: Cli,
    settings: *config.Settings,
    pty: term.Pty,
    tap: *tap_mod.Tap,
    fixed: term.LineParams,
    web_server: ?web.Server = null,

    link_buf: [posix.PATH_MAX]u8 = undefined,
    link_len: usize = 0,
    link_published: bool = false,
    link_error_logged: bool = false,
    last_link_try_ms: i64 = 0,

    serial_fd: ?posix.fd_t = null,
    serial_label: [64]u8 = undefined,
    serial_label_len: usize = 0,
    last_serial_err: []const u8 = "",
    applied: ?term.LineParams = null,
    last_requested: term.LineParams,
    next_open_ms: i64 = 0,
    last_sync_ms: i64 = 0,
    host_stalled: bool = false,

    child_pid: ?posix.pid_t = null,
    last_http_ms: i64 = 0,
    last_traffic_ms: i64 = 0,
    stats: Stats = .{},

    // ----- main loop ------------------------------------------------------

    fn run(self: *Bridge) !void {
        var buf: [io_buf_size]u8 = undefined;

        while (!shutdown_requested.load(.acquire)) {
            if (self.reapChildren()) return;

            const now = std.time.milliTimestamp();
            if (self.serial_fd == null) self.tryOpenSerial(now);
            if (!self.link_published and now - self.last_link_try_ms >= link_retry_ms) {
                self.last_link_try_ms = now;
                self.tryPublishLink();
            }
            if (now - self.last_sync_ms >= poll_interval_ms) {
                self.last_sync_ms = now;
                self.syncLineParams();
            }
            if (self.shouldIdleExit(now)) {
                log.info("idle for a while with nothing to do; closing", .{});
                return;
            }

            var fds: [3]posix.pollfd = undefined;
            var n: usize = 0;
            fds[n] = .{ .fd = self.pty.master, .events = posix.POLL.IN, .revents = 0 };
            n += 1;
            var serial_idx: ?usize = null;
            var web_idx: ?usize = null;
            if (self.serial_fd) |sfd| {
                serial_idx = n;
                fds[n] = .{ .fd = sfd, .events = posix.POLL.IN, .revents = 0 };
                n += 1;
            }
            if (self.web_server) |ws| {
                web_idx = n;
                fds[n] = .{ .fd = ws.fd, .events = posix.POLL.IN, .revents = 0 };
                n += 1;
            }

            const ready = try posix.poll(fds[0..n], poll_interval_ms);
            if (ready == 0) continue;

            if (fds[0].revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return error.PtyFailed;
            if (fds[0].revents & posix.POLL.IN != 0) self.pumpHostToDevice(&buf);
            if (serial_idx) |i| {
                if (fds[i].revents != 0) self.pumpDeviceToHost(&buf, fds[i].revents);
            }
            if (web_idx) |i| {
                if (fds[i].revents & posix.POLL.IN != 0) self.web_server.?.serviceOne(self, handleHttp, self.gpa);
            }
        }
    }

    fn shouldIdleExit(self: *Bridge, now: i64) bool {
        if (self.child_pid != null) return false;
        if (self.cli.mode != .app and self.cli.mode != .ui and !self.cli.idle_exit) return false;
        // Traffic with the reader counts as use: Diver-Office may be running without us having
        // launched it, and the window may be closed.
        return now - @max(self.last_http_ms, self.last_traffic_ms) > idle_exit_ms;
    }

    /// Reap any exited child (xdg-open helpers, Wine). True if the supervised
    /// command exited, meaning diveZ should shut down.
    fn reapChildren(self: *Bridge) bool {
        while (true) {
            var status: u32 = 0;
            const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);
            if (linux.E.init(rc) != .SUCCESS or rc == 0) return false;
            const pid: posix.pid_t = @intCast(rc);
            if (self.child_pid) |cp| {
                if (cp == pid) {
                    self.child_pid = null;
                    log.info("Diver-Office / supervised command exited; shutting down", .{});
                    return true;
                }
            }
        }
    }

    // ----- data path ------------------------------------------------------

    /// Wine -> physical unit.
    fn pumpHostToDevice(self: *Bridge, buf: []u8) void {
        const n = switch (term.rawRead(self.pty.master, buf)) {
            .bytes => |n| n,
            .would_block => return,
            .failed => |e| {
                log.warn("pty read failed: {s}", .{@tagName(e)});
                return;
            },
        };
        if (n == 0) return;
        const chunk = buf[0..n];
        self.dump("W->D", chunk);

        if (self.serial_fd) |sfd| {
            term.writeAll(sfd, chunk, device_write_timeout_ms) catch |err| {
                self.stats.dropped_to_device += n;
                self.tap.onChunk(.host_to_device, chunk);
                self.dropSerial(@errorName(err));
                return;
            };
            self.stats.host_to_device += n;
            self.last_traffic_ms = std.time.milliTimestamp();
        } else {
            self.stats.dropped_to_device += n; // device gone: never block Wine forever
        }
        self.tap.onChunk(.host_to_device, chunk);
    }

    /// Physical unit -> Wine.
    fn pumpDeviceToHost(self: *Bridge, buf: []u8, revents: i16) void {
        const sfd = self.serial_fd orelse return;

        if (revents & posix.POLL.IN != 0) {
            switch (term.rawRead(sfd, buf)) {
                .bytes => |n| if (n > 0) {
                    const chunk = buf[0..n];
                    self.dump("D->W", chunk);
                    self.tap.onChunk(.device_to_host, chunk);
                    if (term.writeAll(self.pty.master, chunk, pty_write_timeout_ms)) |_| {
                        self.stats.device_to_host += n;
                        self.last_traffic_ms = std.time.milliTimestamp();
                        self.host_stalled = false;
                    } else |_| {
                        self.stats.dropped_to_host += n;
                        if (!self.host_stalled) {
                            self.host_stalled = true;
                            log.warn("Wine side not consuming data; dropping device bytes", .{});
                        }
                    }
                },
                .would_block => {},
                .failed => |e| {
                    self.dropSerial(@tagName(e));
                    return;
                },
            }
        }
        if (revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0)
            self.dropSerial("hangup/error on device node");
    }

    // ----- serial lifecycle -----------------------------------------------

    fn noteSerialError(self: *Bridge, code: []const u8, what: []const u8) void {
        if (std.mem.eql(u8, self.last_serial_err, code)) return;
        self.last_serial_err = code;
        log.warn("serial unavailable ({s}): {s}", .{ code, what });
    }

    fn tryOpenSerial(self: *Bridge, now: i64) void {
        if (now < self.next_open_ms) return;
        self.next_open_ms = now + reopen_interval_ms;

        var pbuf: [64]u8 = undefined;
        const path: [:0]const u8 = blk: {
            if (std.mem.eql(u8, self.settings.serial, "auto")) {
                break :blk config.autoSerial(&pbuf) orelse {
                    self.noteSerialError("missing", "no USB serial device found");
                    return;
                };
            }
            break :blk std.fmt.bufPrintZ(&pbuf, "{s}", .{self.settings.serial}) catch return;
        };

        const fd = term.openSerial(path) catch |err| {
            const code: []const u8 = switch (err) {
                error.AccessDenied => "permission",
                error.FileNotFound, error.NoDevice => "missing",
                else => @errorName(err),
            };
            self.noteSerialError(code, path);
            return;
        };

        const params = self.desiredParams();
        term.applyRaw(fd, params) catch |err| {
            log.err("termios setup failed on {s}: {s}", .{ path, @errorName(err) });
            self.noteSerialError("not_serial", path);
            posix.close(fd);
            return;
        };
        if (self.cli.assert_dtr_rts) term.assertDtrRts(fd);
        _ = c.tcflush(fd, c.TCIOFLUSH);

        self.serial_fd = fd;
        self.applied = params;
        self.last_serial_err = "";
        self.stats.reconnects += 1;
        self.tap.sessionBoundary();
        const lbl = std.fmt.bufPrint(&self.serial_label, "{s}", .{path}) catch "";
        self.serial_label_len = lbl.len;

        var b: [32]u8 = undefined;
        log.info("serial {s} online ({s}, raw)", .{ path, params.describe(&b) });
    }

    fn dropSerial(self: *Bridge, reason: []const u8) void {
        if (self.serial_fd) |fd| posix.close(fd);
        self.serial_fd = null;
        self.applied = null;
        self.next_open_ms = std.time.milliTimestamp() + 500;
        self.tap.sessionBoundary();
        log.warn("serial link lost: {s}; will retry", .{reason});
    }

    /// Settings changed: close the port quietly so the next tick reopens it.
    fn resetSerial(self: *Bridge) void {
        if (self.serial_fd) |fd| posix.close(fd);
        self.serial_fd = null;
        self.applied = null;
        self.next_open_ms = 0;
        self.last_serial_err = "";
        self.tap.sessionBoundary();
    }

    fn desiredParams(self: *Bridge) term.LineParams {
        if (!self.cli.mirror) return self.fixed;
        if (term.readParams(self.pty.keepalive)) |p| {
            self.last_requested = p;
        } else |_| {} // B0/BOTHER/transient: keep the last good value
        return self.last_requested;
    }

    /// Follow whatever Wine configured via SetCommState.
    fn syncLineParams(self: *Bridge) void {
        const sfd = self.serial_fd orelse return;
        const want = self.desiredParams();
        if (self.applied) |a| if (a.eql(want)) return;

        term.applyRaw(sfd, want) catch |err| {
            log.err("failed to apply line params: {s}", .{@errorName(err)});
            return;
        };
        self.applied = want;
        var b: [32]u8 = undefined;
        log.info("line params -> {s}", .{want.describe(&b)});
    }

    fn dump(self: *Bridge, label: []const u8, bytes: []const u8) void {
        if (self.cli.verbose) log.debug("{s} {d}B: {x}", .{ label, bytes.len, bytes });
    }

    // ----- Wine-facing COM link -------------------------------------------

    fn linkPath(self: *const Bridge) []const u8 {
        return self.link_buf[0..self.link_len];
    }

    fn removeLink(self: *Bridge) void {
        if (self.link_published) posix.unlink(self.linkPath()) catch {};
        self.link_published = false;
        self.link_error_logged = false;
    }

    /// Compute the COM link path from CLI/settings and try to publish it.
    fn setupLink(self: *Bridge) void {
        self.removeLink();
        self.link_len = 0;
        var pb: [posix.PATH_MAX]u8 = undefined;
        const text = if (self.cli.link) |l|
            std.fmt.bufPrint(&self.link_buf, "{s}", .{l}) catch return
        else blk: {
            const prefix = config.resolvePrefix(self.settings, &pb) catch return;
            break :blk std.fmt.bufPrint(&self.link_buf, "{s}/dosdevices/com9", .{prefix}) catch return;
        };
        self.link_len = text.len;
        self.tryPublishLink();
    }

    fn tryPublishLink(self: *Bridge) void {
        if (self.link_published or self.link_len == 0) return;
        const link = self.linkPath();
        const dir = std.fs.path.dirname(link) orelse return;
        // Never create the Wine prefix ourselves; wait until Wine has.
        std.fs.cwd().access(dir, .{}) catch return;
        publishLink(link, self.pty.slavePath()) catch |err| {
            if (!self.link_error_logged) {
                log.err("cannot publish {s}: {s}", .{ link, @errorName(err) });
                self.link_error_logged = true;
            }
            return;
        };
        self.link_published = true;
        log.info("Wine endpoint: {s} -> {s}", .{ link, self.pty.slavePath() });
    }

    // ----- launching ------------------------------------------------------

    fn resolveExe(self: *Bridge, a: std.mem.Allocator) ?[]const u8 {
        if (self.settings.exe.len > 0) return self.settings.exe;
        var pb: [posix.PATH_MAX]u8 = undefined;
        const prefix = config.resolvePrefix(self.settings, &pb) catch return null;
        const exes = config.findExes(a, prefix) catch return null;
        return if (exes.len > 0) exes[0] else null;
    }

    fn launchDiver(self: *Bridge) LaunchError!void {
        if (self.child_pid != null) return error.AlreadyRunning;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var wbuf: [posix.PATH_MAX]u8 = undefined;
        const wine = wineBinary(&wbuf) orelse return error.WineNotFound;
        const exe = self.resolveExe(a) orelse return error.ExeNotFound;

        var pb: [posix.PATH_MAX]u8 = undefined;
        const prefix = config.resolvePrefix(self.settings, &pb) catch return error.SpawnFailed;
        var env = std.process.getEnvMap(a) catch return error.SpawnFailed;
        env.put("WINEPREFIX", prefix) catch return error.SpawnFailed;
        if (posix.getenv("WINEDEBUG") == null) env.put("WINEDEBUG", "-all") catch return error.SpawnFailed;

        var child = std.process.Child.init(&[_][]const u8{ wine, exe }, a);
        child.env_map = &env;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return error.SpawnFailed;
        self.child_pid = child.id;
        log.info("started Diver-Office (pid {d}): {s}", .{ child.id, exe });
    }

    fn openUi(self: *Bridge) void {
        const ws = self.web_server orelse return;
        var ub: [96]u8 = undefined;
        const url = ws.url(&ub) catch return;
        openUrl(self.gpa, url);
    }

    // ----- HTTP routes ----------------------------------------------------

    fn route(self: *Bridge, req: web.Request, a: std.mem.Allocator, res: *web.Response) !void {
        const get = std.mem.eql(u8, req.method, "GET");
        const post = std.mem.eql(u8, req.method, "POST");
        const p = req.path;

        if (get and std.mem.eql(u8, p, "/")) {
            res.content_type = "text/html";
            res.body = ui_html;
            return;
        }
        if (get and std.mem.eql(u8, p, "/api/status")) return self.writeStatus(a, res);

        if (get and std.mem.eql(u8, p, "/api/detect")) {
            var pb: [posix.PATH_MAX]u8 = undefined;
            const prefix = config.resolvePrefix(self.settings, &pb) catch "";
            return jsonBody(a, res, .{
                .serials = try config.listSerials(a),
                .exes = try config.findExes(a, prefix),
            });
        }

        if (post and std.mem.eql(u8, p, "/api/launch")) {
            self.launchDiver() catch |err| return jsonBody(a, res, .{ .ok = false, .reason = @errorName(err) });
            return jsonBody(a, res, .{ .ok = true });
        }

        if (post and std.mem.eql(u8, p, "/api/open-captures")) {
            var cb: [posix.PATH_MAX]u8 = undefined;
            const dir = try config.resolveCaptureDir(self.settings, &cb);
            try std.fs.cwd().makePath(dir);
            openUrl(self.gpa, dir);
            return jsonBody(a, res, .{ .ok = true });
        }

        if (post and std.mem.eql(u8, p, "/api/quit")) {
            shutdown_requested.store(true, .release);
            return jsonBody(a, res, .{ .ok = true });
        }

        if (post and std.mem.eql(u8, p, "/api/config")) return self.applyConfig(req, a, res);

        res.status = 404;
        res.content_type = "text/plain";
        res.body = "not found";
    }

    fn applyConfig(self: *Bridge, req: web.Request, a: std.mem.Allocator, res: *web.Response) !void {
        const Body = struct {
            serial: ?[]const u8 = null,
            prefix: ?[]const u8 = null,
            exe: ?[]const u8 = null,
            capture_dir: ?[]const u8 = null,
            autolaunch: ?bool = null,
        };
        const parsed = std.json.parseFromSlice(Body, a, req.body, .{ .ignore_unknown_fields = true }) catch
            return fail(a, res, 400, "bad json");
        const b = parsed.value;

        if (b.serial) |v| if (!config.validSerial(v)) return fail(a, res, 400, "invalid serial");
        if (b.prefix) |v| if (!config.validPrefix(v)) return fail(a, res, 400, "invalid prefix");
        if (b.exe) |v| if (!config.validExe(v)) return fail(a, res, 400, "invalid exe");
        if (b.capture_dir) |v| if (!config.validCaptureDir(v)) return fail(a, res, 400, "invalid capture_dir");

        var serial_changed = false;
        var prefix_changed = false;
        if (b.serial) |v| {
            if (!std.mem.eql(u8, v, self.settings.serial)) {
                try self.settings.setString("serial", v);
                serial_changed = true;
            }
        }
        if (b.prefix) |v| {
            if (!std.mem.eql(u8, v, self.settings.prefix)) {
                try self.settings.setString("prefix", v);
                prefix_changed = true;
            }
        }
        if (b.exe) |v| try self.settings.setString("exe", v);
        var capture_changed = false;
        if (b.capture_dir) |v| if (!std.mem.eql(u8, v, self.settings.capture_dir)) {
            try self.settings.setString("capture_dir", v);
            capture_changed = true;
        };
        if (b.autolaunch) |v| self.settings.autolaunch = v;

        var saved = true;
        config.save(self.settings) catch |err| {
            log.warn("could not save settings: {s}", .{@errorName(err)});
            saved = false;
        };
        if (serial_changed) self.resetSerial();
        if (prefix_changed) self.setupLink();
        // The capture files are opened at startup, so a new directory applies on next start.
        return jsonBody(a, res, .{ .ok = true, .saved = saved, .restart_required = capture_changed });
    }

    fn writeStatus(self: *Bridge, a: std.mem.Allocator, res: *web.Response) !void {
        var db: [64]u8 = undefined;
        const line: []const u8 = if (self.applied) |ap| ap.describe(&db) else "";
        var wb: [posix.PATH_MAX]u8 = undefined;
        var cb: [posix.PATH_MAX]u8 = undefined;
        const capture = config.resolveCaptureDir(self.settings, &cb) catch "";

        try jsonBody(a, res, .{
            .version = config.version,
            .serial_online = self.serial_fd != null,
            .serial_path = self.serial_label[0..self.serial_label_len],
            .serial_error = self.last_serial_err,
            .line = line,
            .wine_found = wineBinary(&wb) != null,
            .prefix_ready = self.link_published,
            .exe = self.resolveExe(a) orelse "",
            .diver_running = self.child_pid != null,
            .to_device = self.stats.host_to_device,
            .from_device = self.stats.device_to_host,
            .capture_dir = capture,
            .rss_kb = config.rssKb(),
            .settings = .{
                .serial = self.settings.serial,
                .prefix = self.settings.prefix,
                .exe = self.settings.exe,
                .capture_dir = self.settings.capture_dir,
                .autolaunch = self.settings.autolaunch,
            },
        });
    }
};

fn handleHttp(ctx: *anyopaque, req: web.Request, a: std.mem.Allocator, res: *web.Response) void {
    const self: *Bridge = @ptrCast(@alignCast(ctx));
    self.last_http_ms = std.time.milliTimestamp();
    self.route(req, a, res) catch |err| fail(a, res, 500, @errorName(err));
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Launched from a desktop icon there is no terminal; keep the log of the last
/// run in ~/diveZ/divez.log so users can attach it when asking for help.
/// DIVEZ_LOG=stderr keeps logging on stderr.
fn redirectLogIfDetached(cli: Cli) void {
    if (!cli.detach and cli.mode != .app and cli.mode != .ui) return;
    if (posix.isatty(posix.STDERR_FILENO)) return;
    if (posix.getenv("DIVEZ_LOG")) |v| {
        if (std.mem.eql(u8, v, "stderr")) return;
    }
    const home = config.homeDir() catch return;
    var db: [posix.PATH_MAX]u8 = undefined;
    const dir = std.fmt.bufPrint(&db, "{s}/diveZ", .{home}) catch return;
    std.fs.cwd().makePath(dir) catch return;
    var pb: [posix.PATH_MAX]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/divez.log", .{dir}) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    posix.dup2(f.handle, posix.STDERR_FILENO) catch {};
}

/// Continue in the background: the launching process returns at once, and we run in a new
/// session with no terminal, so closing the window or terminal that started us does not stop us.
fn detachFromTerminal() void {
    const pid = posix.fork() catch |err| {
        log.err("cannot run in the background: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    if (pid != 0) std.process.exit(0); // the launcher
    _ = linux.setsid();
    const null_fd = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch return;
    for ([_]posix.fd_t{ posix.STDIN_FILENO, posix.STDOUT_FILENO, posix.STDERR_FILENO }) |fd| {
        posix.dup2(null_fd, fd) catch {};
    }
    if (null_fd > posix.STDERR_FILENO) posix.close(null_fd);
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const cli = parseArgs(args) catch {
        usage();
        std.process.exit(2);
    };

    // Before anything else is set up: the lock file must record the pid that keeps running.
    if (cli.detach) detachFromTerminal();
    redirectLogIfDetached(cli);

    var settings = config.Settings.init(gpa);
    defer settings.deinit();
    config.load(&settings);
    if (cli.serial) |v| try settings.override("serial", v);
    if (cli.prefix) |v| try settings.override("prefix", v);
    if (cli.capture_dir) |v| try settings.override("capture_dir", v);

    // Single instance: a second launch just reopens the first one's page.
    const inst = config.acquireInstance() catch |err| {
        log.err("cannot create lock file: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    switch (inst) {
        .running => {
            var ub: [160]u8 = undefined;
            var tries: u8 = 0;
            while (tries < 20) : (tries += 1) {
                if (config.readUrlFile(&ub)) |u| {
                    if (cli.mode != .service) openUrl(gpa, u);
                    std.debug.print("diveZ is already running: {s}\n", .{u});
                    break;
                }
                std.time.sleep(100 * std.time.ns_per_ms);
            }
            std.process.exit(0);
        },
        .acquired => {}, // fd stays open for the life of the process
    }

    const speed = term.speedFromBaud(cli.baud) orelse {
        log.err("unsupported baud rate {d}", .{cli.baud});
        std.process.exit(2);
    };
    const fixed = term.LineParams{ .speed = speed };

    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
    // A browser closing a connection mid-write must not kill the daemon.
    const ign = linux.Sigaction{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.empty_sigset, .flags = 0 };
    _ = linux.sigaction(linux.SIG.PIPE, &ign, null);

    var pty = try term.Pty.open(fixed);
    defer pty.close();

    var capbuf: [posix.PATH_MAX]u8 = undefined;
    const capdir = config.resolveCaptureDir(&settings, &capbuf) catch null;
    var tap = tap_mod.Tap.init(capdir) catch |err| blk: {
        log.warn("captures disabled: {s}", .{@errorName(err)});
        break :blk tap_mod.Tap{};
    };
    defer tap.deinit();

    var bridge = Bridge{
        .gpa = gpa,
        .cli = cli,
        .settings = &settings,
        .pty = pty,
        .tap = &tap,
        .fixed = fixed,
        .last_requested = fixed,
        .last_http_ms = std.time.milliTimestamp(),
    };
    defer if (bridge.serial_fd) |fd| posix.close(fd);

    bridge.web_server = web.Server.init() catch |err| blk: {
        log.warn("settings page unavailable: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (bridge.web_server) |*ws| ws.deinit();
    if (bridge.web_server) |ws| {
        var ub: [96]u8 = undefined;
        if (ws.url(&ub)) |u| config.writeUrlFile(u) else |_| {}
    }
    defer config.removeUrlFile();

    bridge.setupLink();
    defer bridge.removeLink();

    switch (cli.mode) {
        .exec => {
            const argv = try gpa.alloc([]const u8, cli.exec_argv.len);
            defer gpa.free(argv);
            for (cli.exec_argv, 0..) |a, k| argv[k] = a;
            var child = std.process.Child.init(argv, gpa);
            try child.spawn();
            bridge.child_pid = child.id;
            log.info("supervising pid {d}: {s}", .{ child.id, argv[0] });
        },
        .ui => bridge.openUi(),
        .service => {},
        .app => {
            var launched = true;
            if (settings.autolaunch and bridge.link_published) {
                bridge.launchDiver() catch |err| {
                    log.warn("could not start Diver-Office automatically: {s}", .{@errorName(err)});
                    launched = false;
                };
            } else launched = false;
            if (!launched) bridge.openUi(); // something needs the user's attention
        },
    }

    bridge.run() catch |err| log.err("fatal: {s}", .{@errorName(err)});

    if (bridge.child_pid) |pid| {
        posix.kill(pid, posix.SIG.TERM) catch {};
        _ = posix.waitpid(pid, 0);
    }

    const s = bridge.stats;
    log.info("shutdown: W->D {d}B (dropped {d}), D->W {d}B (dropped {d}), connects {d}", .{
        s.host_to_device, s.dropped_to_device, s.device_to_host, s.dropped_to_host, s.reconnects,
    });
}

test {
    _ = term;
    _ = tap_mod;
    _ = config;
    _ = web;
}

test "baud table roundtrip" {
    const s = term.speedFromBaud(9600).?;
    try std.testing.expectEqual(@as(u32, 9600), term.baudFromSpeed(s).?);
    try std.testing.expect(term.speedFromBaud(12345) == null);
}

test "line params describe" {
    var b: [32]u8 = undefined;
    const p = term.LineParams{ .speed = term.speedFromBaud(19200).? };
    try std.testing.expectEqualStrings("19200 8N1", p.describe(&b));
}
