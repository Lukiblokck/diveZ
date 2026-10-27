//! Settings persistence, auto-detection of devices / Wine / Diver-Office, and
//! single-instance bookkeeping. No allocation on the hot path; detection runs
//! only on demand (startup, settings page).

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const version = "0.2.0";

// ---------------------------------------------------------------------------
// Settings (plain key=value file in $XDG_CONFIG_HOME/divez/config)
// ---------------------------------------------------------------------------

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    /// Device path, or "auto" to pick the first USB serial node.
    serial: []const u8 = "auto",
    /// Wine prefix. Empty means $WINEPREFIX or ~/.wine.
    prefix: []const u8 = "",
    /// Windows path of the Diver-Office executable. Empty means auto-detect.
    exe: []const u8 = "",
    /// Where captures are written. Empty means ~/diveZ/captures.
    capture_dir: []const u8 = "",
    autolaunch: bool = true,
    /// File-backed values hidden by a command-line override for this run.
    /// A null entry means the effective value is also the persisted one.
    shadow: struct {
        serial: ?[]const u8 = null,
        prefix: ?[]const u8 = null,
        exe: ?[]const u8 = null,
        capture_dir: ?[]const u8 = null,
    } = .{},

    pub fn init(backing: Allocator) Settings {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Settings) void {
        self.arena.deinit();
    }

    /// Set a value that is also meant to be saved (config file, settings page).
    pub fn setString(self: *Settings, comptime field: []const u8, value: []const u8) !void {
        const copy = try self.arena.allocator().dupe(u8, value);
        @field(self, field) = copy;
        @field(self.shadow, field) = null;
    }

    /// Force a value for this run only (command line). `save` keeps writing the
    /// value that was in the config file, so a flag never leaks into it.
    pub fn override(self: *Settings, comptime field: []const u8, value: []const u8) !void {
        const copy = try self.arena.allocator().dupe(u8, value);
        if (@field(self.shadow, field) == null) @field(self.shadow, field) = @field(self, field);
        @field(self, field) = copy;
    }

    /// The value `save` writes for a string field.
    pub fn persisted(self: *const Settings, comptime field: []const u8) []const u8 {
        return @field(self.shadow, field) orelse @field(self, field);
    }
};

pub fn homeDir() ![]const u8 {
    return posix.getenv("HOME") orelse error.NoHome;
}

fn configFilePath(buf: []u8) ![]const u8 {
    if (posix.getenv("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/divez/config", .{x});
    }
    return std.fmt.bufPrint(buf, "{s}/.config/divez/config", .{try homeDir()});
}

pub fn load(s: *Settings) void {
    var pb: [posix.PATH_MAX]u8 = undefined;
    const path = configFilePath(&pb) catch return;
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "serial")) {
            s.setString("serial", val) catch {};
        } else if (std.mem.eql(u8, key, "prefix")) {
            s.setString("prefix", val) catch {};
        } else if (std.mem.eql(u8, key, "exe")) {
            s.setString("exe", val) catch {};
        } else if (std.mem.eql(u8, key, "capture_dir")) {
            s.setString("capture_dir", val) catch {};
        } else if (std.mem.eql(u8, key, "autolaunch")) {
            s.autolaunch = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
        }
    }
}

pub fn save(s: *const Settings) !void {
    var pb: [posix.PATH_MAX]u8 = undefined;
    const path = try configFilePath(&pb);
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writer().print(
        "# diveZ settings (written by the settings page)\nserial={s}\nprefix={s}\nexe={s}\ncapture_dir={s}\nautolaunch={d}\n",
        .{ s.persisted("serial"), s.persisted("prefix"), s.persisted("exe"), s.persisted("capture_dir"), @intFromBool(s.autolaunch) },
    );
}

// ---------------------------------------------------------------------------
// Validation of values coming from the settings page
// ---------------------------------------------------------------------------

fn printable(s: []const u8) bool {
    for (s) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

pub fn validSerial(v: []const u8) bool {
    if (std.mem.eql(u8, v, "auto")) return true;
    return v.len > 5 and v.len < 64 and std.mem.startsWith(u8, v, "/dev/") and
        printable(v) and std.mem.indexOf(u8, v, "..") == null;
}

pub fn validPrefix(v: []const u8) bool {
    if (v.len == 0) return true;
    return v.len < 400 and v[0] == '/' and printable(v) and std.mem.indexOf(u8, v, "..") == null;
}

/// Same rules as a Wine prefix: empty (use the default) or an absolute path.
pub fn validCaptureDir(v: []const u8) bool {
    return validPrefix(v);
}

pub fn validExe(v: []const u8) bool {
    return v.len < 400 and printable(v);
}

// ---------------------------------------------------------------------------
// Well-known paths
// ---------------------------------------------------------------------------

/// Settings value > $WINEPREFIX > ~/.wine
pub fn resolvePrefix(s: *const Settings, buf: []u8) ![]const u8 {
    if (s.prefix.len > 0) return s.prefix;
    if (posix.getenv("WINEPREFIX")) |p| {
        if (p.len > 0) return p;
    }
    return std.fmt.bufPrint(buf, "{s}/.wine", .{try homeDir()});
}

pub fn resolveCaptureDir(s: *const Settings, buf: []u8) ![]const u8 {
    if (s.capture_dir.len > 0) return s.capture_dir;
    return std.fmt.bufPrint(buf, "{s}/diveZ/captures", .{try homeDir()});
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

fn pathLess(_: void, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len < b.len; // natural order: ttyUSB2 before ttyUSB10
    return std.mem.lessThan(u8, a, b);
}

/// USB serial nodes, best candidate first. /dev/diver0 (udev alias) wins.
pub fn listSerials(a: Allocator) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var dir = std.fs.openDirAbsolute("/dev", .{ .iterate = true }) catch return out.toOwnedSlice();
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (std.mem.startsWith(u8, e.name, "ttyUSB") or std.mem.startsWith(u8, e.name, "ttyACM")) {
            try out.append(try std.fmt.allocPrint(a, "/dev/{s}", .{e.name}));
        }
    }
    std.mem.sort([]const u8, out.items, {}, pathLess);
    if (std.fs.accessAbsolute("/dev/diver0", .{})) |_| {
        try out.insert(0, "/dev/diver0");
    } else |_| {}
    return out.toOwnedSlice();
}

/// First detected serial node, as a NUL-terminated path inside `buf`.
pub fn autoSerial(buf: *[64]u8) ?[:0]const u8 {
    var fba_buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const list = listSerials(fba.allocator()) catch return null;
    if (list.len == 0) return null;
    return std.fmt.bufPrintZ(buf, "{s}", .{list[0]}) catch null;
}

fn isDiverExe(name: []const u8) bool {
    if (!std.ascii.endsWithIgnoreCase(name, ".exe")) return false;
    if (std.ascii.indexOfIgnoreCase(name, "diver") == null) return false;
    return std.ascii.indexOfIgnoreCase(name, "unins") == null and
        std.ascii.indexOfIgnoreCase(name, "setup") == null;
}

fn scanExes(a: Allocator, dir: std.fs.Dir, win_dir: []const u8, depth: u8, out: *std.ArrayList([]const u8)) !void {
    var it = dir.iterate();
    while (try it.next()) |e| {
        switch (e.kind) {
            .file => {
                if (isDiverExe(e.name)) try out.append(try std.fmt.allocPrint(a, "{s}\\{s}", .{ win_dir, e.name }));
            },
            .directory => {
                if (depth == 0) continue;
                var sub = dir.openDir(e.name, .{ .iterate = true }) catch continue;
                defer sub.close();
                const w = try std.fmt.allocPrint(a, "{s}\\{s}", .{ win_dir, e.name });
                try scanExes(a, sub, w, depth - 1, out);
            },
            else => {},
        }
    }
}

/// Windows-style paths of Diver executables found inside the prefix.
pub fn findExes(a: Allocator, prefix: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    const roots = [_][]const u8{ "Program Files", "Program Files (x86)" };
    for (roots) |root| {
        const p = try std.fmt.allocPrint(a, "{s}/drive_c/{s}", .{ prefix, root });
        var dir = std.fs.cwd().openDir(p, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .directory) continue;
            if (std.ascii.indexOfIgnoreCase(e.name, "van essen") == null and
                std.ascii.indexOfIgnoreCase(e.name, "diver") == null) continue;
            var sub = dir.openDir(e.name, .{ .iterate = true }) catch continue;
            defer sub.close();
            const w = try std.fmt.allocPrint(a, "C:\\{s}\\{s}", .{ root, e.name });
            try scanExes(a, sub, w, 2, &out);
        }
    }
    return out.toOwnedSlice();
}

pub fn findInPath(name: []const u8, buf: []u8) ?[]const u8 {
    const path_env = posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const p = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch continue;
        posix.access(p, posix.X_OK) catch continue;
        return p;
    }
    return null;
}

/// Resident memory of this process in KiB (from /proc/self/statm).
pub fn rssKb() u64 {
    var buf: [128]u8 = undefined;
    const f = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch return 0;
    defer f.close();
    const n = f.readAll(&buf) catch return 0;
    var it = std.mem.tokenizeAny(u8, buf[0..n], " \n");
    _ = it.next();
    const pages = std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch return 0;
    return pages * 4;
}

// ---------------------------------------------------------------------------
// Single instance: a flock'ed lock file plus a file holding the UI address, so
// a second launch just reopens the first instance's page.
// ---------------------------------------------------------------------------

pub const Instance = union(enum) { acquired: posix.fd_t, running };

/// Directories where the lock and address files may live, most preferred first:
/// $XDG_RUNTIME_DIR, /run/user/<uid> if it exists, /tmp. The daemon writes to the first one; a
/// reader checks all of them, so a window started without the same environment as the daemon
/// (common without a login manager) still finds it.
pub const RunDirs = struct {
    items: [3][]const u8 = undefined,
    len: usize = 0,
    uid_dir: [64]u8 = undefined, // backing storage of "/run/user/<uid>"

    pub fn slice(self: *const RunDirs) []const []const u8 {
        return self.items[0..self.len];
    }
};

/// Pure part of `runDirs`, separated so it can be tested.
pub fn runDirsFrom(rd: *RunDirs, xdg: ?[]const u8, uid: u32, run_user_exists: bool) void {
    rd.len = 0;
    if (xdg) |d| {
        if (d.len > 0) {
            rd.items[rd.len] = d;
            rd.len += 1;
        }
    }
    if (run_user_exists) {
        if (std.fmt.bufPrint(&rd.uid_dir, "/run/user/{d}", .{uid})) |dir| {
            if (rd.len == 0 or !std.mem.eql(u8, rd.items[0], dir)) {
                rd.items[rd.len] = dir;
                rd.len += 1;
            }
        } else |_| {}
    }
    rd.items[rd.len] = "/tmp";
    rd.len += 1;
}

pub fn runDirs(rd: *RunDirs) void {
    const uid = std.os.linux.getuid();
    var pb: [64]u8 = undefined;
    const run = std.fmt.bufPrint(&pb, "/run/user/{d}", .{uid}) catch "/nonexistent";
    const exists = if (std.fs.cwd().access(run, .{})) true else |_| false;
    runDirsFrom(rd, posix.getenv("XDG_RUNTIME_DIR"), uid, exists);
}

/// `<dir>/divez-<uid>.<ext>`
pub fn runtimeFileIn(buf: []u8, dir: []const u8, ext: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/divez-{d}.{s}", .{ dir, std.os.linux.getuid(), ext });
}

fn runtimeFile(buf: []u8, ext: []const u8) ![]const u8 {
    var rd: RunDirs = .{};
    runDirs(&rd);
    return runtimeFileIn(buf, rd.items[0], ext);
}

/// The address file in `dir`, trimmed, or null if it is missing or empty.
pub fn readUrlFileIn(dir: []const u8, buf: []u8) ?[]const u8 {
    var pb: [posix.PATH_MAX]u8 = undefined;
    const path = runtimeFileIn(&pb, dir, "url") catch return null;
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return if (n == 0) null else std.mem.trim(u8, buf[0..n], " \r\n");
}

/// The pid the daemon recorded in its lock file in `dir`, if that process is still a diveZ.
pub fn daemonPidIn(dir: []const u8) ?posix.pid_t {
    var pb: [posix.PATH_MAX]u8 = undefined;
    const path = runtimeFileIn(&pb, dir, "lock") catch return null;
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var buf: [32]u8 = undefined;
    const n = f.readAll(&buf) catch return null;
    const pid = std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, buf[0..n], " \r\n"), 10) catch return null;
    return if (processIsDiveZ(pid)) pid else null;
}

/// True when `pid` is a live (not zombie) process whose command name starts with "divez". The
/// lock file may be stale and the pid reused by something else.
pub fn processIsDiveZ(pid: posix.pid_t) bool {
    if (pid <= 0) return false;
    var pb: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/proc/{d}/stat", .{pid}) catch return false;
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = f.readAll(&buf) catch return false;
    return statIsDiveZ(buf[0..n]);
}

/// `stat` is the content of /proc/<pid>/stat: "<pid> (<comm>) <state> ...". The name may contain
/// spaces and parentheses, so the closing one is the last one.
pub fn statIsDiveZ(stat: []const u8) bool {
    const open = std.mem.indexOfScalar(u8, stat, '(') orelse return false;
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
    if (close <= open or close + 2 >= stat.len) return false;
    const state = stat[close + 2];
    if (state == 'Z' or state == 'X') return false;
    return std.mem.startsWith(u8, stat[open + 1 .. close], "divez");
}

/// The pid of a running diveZ daemon of this user, looking in every candidate directory.
pub fn findDaemonPid() ?posix.pid_t {
    var rd: RunDirs = .{};
    runDirs(&rd);
    for (rd.slice()) |dir| {
        if (daemonPidIn(dir)) |pid| return pid;
    }
    return null;
}

pub fn acquireInstance() !Instance {
    var pb: [posix.PATH_MAX]u8 = undefined;
    const path = try runtimeFile(&pb, "lock");
    const fd = try posix.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => {
            posix.close(fd);
            return .running;
        },
        else => return err,
    };
    // Record our pid so a reader can tell "running" from a stale file without taking the lock.
    var pidb: [24]u8 = undefined;
    if (std.fmt.bufPrint(&pidb, "{d}\n", .{std.os.linux.getpid()})) |txt| {
        posix.ftruncate(fd, 0) catch {};
        _ = posix.pwrite(fd, txt, 0) catch 0;
    } else |_| {}
    return .{ .acquired = fd };
}

pub fn writeUrlFile(url: []const u8) void {
    var pb: [posix.PATH_MAX]u8 = undefined;
    const path = runtimeFile(&pb, "url") catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 }) catch return;
    defer f.close();
    f.writeAll(url) catch {};
}

pub fn removeUrlFile() void {
    var pb: [posix.PATH_MAX]u8 = undefined;
    const path = runtimeFile(&pb, "url") catch return;
    posix.unlink(path) catch {};
}

/// The address file of a running diveZ: the first candidate directory that has one.
pub fn readUrlFile(buf: []u8) ?[]const u8 {
    var rd: RunDirs = .{};
    runDirs(&rd);
    for (rd.slice()) |dir| {
        if (readUrlFileIn(dir, buf)) |u| return u;
    }
    return null;
}

test "validators" {
    try std.testing.expect(validSerial("auto"));
    try std.testing.expect(validSerial("/dev/ttyUSB0"));
    try std.testing.expect(!validSerial("/etc/passwd"));
    try std.testing.expect(!validSerial("/dev/../etc/passwd"));
    try std.testing.expect(validPrefix(""));
    try std.testing.expect(!validPrefix("relative/path"));
    try std.testing.expect(!validExe("a\nb"));
}

test "natural order" {
    try std.testing.expect(pathLess({}, "/dev/ttyUSB2", "/dev/ttyUSB10"));
}

test "diver exe filter" {
    try std.testing.expect(isDiverExe("DiverOffice.exe"));
    try std.testing.expect(!isDiverExe("unins000.exe"));
    try std.testing.expect(!isDiverExe("Diver-Setup.exe"));
    try std.testing.expect(!isDiverExe("readme.txt"));
}

test "cli override is not persisted" {
    var s = Settings.init(std.testing.allocator);
    defer s.deinit();
    try s.setString("serial", "/dev/ttyUSB1"); // as if loaded from the file
    try s.override("serial", "/dev/ttyUSB7"); // --serial
    try s.override("serial", "/dev/ttyUSB8"); // a second override keeps the file value
    try std.testing.expectEqualStrings("/dev/ttyUSB8", s.serial);
    try std.testing.expectEqualStrings("/dev/ttyUSB1", s.persisted("serial"));
    try s.setString("serial", "/dev/ttyACM0"); // the settings page chose a value
    try std.testing.expectEqualStrings("/dev/ttyACM0", s.persisted("serial"));
    try std.testing.expectEqualStrings("", s.persisted("capture_dir"));
}

test "capture dir validator" {
    try std.testing.expect(validCaptureDir(""));
    try std.testing.expect(validCaptureDir("/home/u/diveZ/captures"));
    try std.testing.expect(!validCaptureDir("relative/dir"));
    try std.testing.expect(!validCaptureDir("/home/u/../etc"));
    try std.testing.expect(!validCaptureDir("/tmp/a\nb"));
}

test "runtime directory candidates" {
    var rd: RunDirs = .{};
    runDirsFrom(&rd, "/run/user/1000", 1000, true); // the usual desktop case: both are the same
    try std.testing.expectEqual(@as(usize, 2), rd.len);
    try std.testing.expectEqualStrings("/run/user/1000", rd.items[0]);
    try std.testing.expectEqualStrings("/tmp", rd.items[1]);

    runDirsFrom(&rd, null, 1000, false); // no login manager: nothing but /tmp
    try std.testing.expectEqual(@as(usize, 1), rd.len);
    try std.testing.expectEqualStrings("/tmp", rd.items[0]);

    runDirsFrom(&rd, "", 1000, true); // empty variable counts as unset
    try std.testing.expectEqualStrings("/run/user/1000", rd.items[0]);

    runDirsFrom(&rd, "/custom", 1000, true); // all three, preferred first
    try std.testing.expectEqual(@as(usize, 3), rd.len);
    try std.testing.expectEqualStrings("/custom", rd.items[0]);
    try std.testing.expectEqualStrings("/run/user/1000", rd.items[1]);
}

test "stat line parsing" {
    try std.testing.expect(statIsDiveZ("123 (divez) S 1 123 123 0 -1"));
    try std.testing.expect(statIsDiveZ("123 (divez-x86_64) R 1 123"));
    try std.testing.expect(!statIsDiveZ("123 (divez) Z 1 123")); // exited, not yet reaped
    try std.testing.expect(!statIsDiveZ("123 (bash) S 1 123"));
    try std.testing.expect(!statIsDiveZ("123 (a) divez) S 1")); // a name cannot hide behind ')'
    try std.testing.expect(!statIsDiveZ(""));
}

test "pid check recognises a diveZ process only" {
    try std.testing.expect(!processIsDiveZ(0));
    try std.testing.expect(!processIsDiveZ(-5));
    try std.testing.expect(!processIsDiveZ(std.os.linux.getpid())); // the test runner is not "divez..."
}
