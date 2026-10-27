//! Editable copy of the daemon's settings plus validation. No UI code here: the
//! rules come from the same validators the daemon applies (src/config.zig), so
//! the window and the daemon cannot disagree about what is valid.
const std = @import("std");
const config = @import("config");
const client = @import("client.zig");

/// Longest valid value is 399 bytes (see config.validPrefix / validExe); one more for the NUL.
pub const max_text = 400;

pub const Field = enum { serial, prefix, exe, capture_dir };
const field_count = @typeInfo(Field).Enum.fields.len;

pub const Form = struct {
    serial: [max_text]u8 = [_]u8{0} ** max_text,
    prefix: [max_text]u8 = [_]u8{0} ** max_text,
    exe: [max_text]u8 = [_]u8{0} ** max_text,
    capture_dir: [max_text]u8 = [_]u8{0} ** max_text,
    autolaunch: bool = true,
    /// Per-field problem to show under the field. Strings are static.
    errors: [field_count]?[]const u8 = [_]?[]const u8{null} ** field_count,
    /// Per-field hint that does not block saving (a path that does not exist yet). Static strings.
    warnings: [field_count]?[]const u8 = [_]?[]const u8{null} ** field_count,

    pub fn get(self: *const Form, comptime f: Field) []const u8 {
        return std.mem.sliceTo(&@field(self, @tagName(f)), 0);
    }

    /// False (and nothing written) when `value` does not fit.
    pub fn set(self: *Form, comptime f: Field, value: []const u8) bool {
        const buf = &@field(self, @tagName(f));
        if (value.len >= buf.len) return false;
        @memset(buf, 0);
        @memcpy(buf[0..value.len], value);
        return true;
    }

    /// Same as `set` for a field only known at run time.
    pub fn setField(self: *Form, f: Field, value: []const u8) bool {
        return switch (f) {
            inline else => |ff| self.set(ff, value),
        };
    }

    pub fn errorOf(self: *const Form, f: Field) ?[]const u8 {
        return self.errors[@intFromEnum(f)];
    }

    pub fn setError(self: *Form, f: Field, msg: ?[]const u8) void {
        self.errors[@intFromEnum(f)] = msg;
    }

    pub fn warningOf(self: *const Form, f: Field) ?[]const u8 {
        return self.warnings[@intFromEnum(f)];
    }

    /// Refresh the non-blocking hints. It looks at the file system, so call it when a value
    /// changes (load, typing, picking), not on every frame.
    pub fn checkPaths(self: *Form) void {
        self.warnings = .{
            serialWarning(self.get(.serial)),
            prefixWarning(self.get(.prefix)),
            exeWarning(self.get(.exe)),
            captureWarning(self.get(.capture_dir)),
        };
    }

    pub fn clearErrors(self: *Form) void {
        self.errors = [_]?[]const u8{null} ** field_count;
    }

    pub fn load(self: *Form, s: client.Settings) void {
        // The daemon only stores values that passed validation, so they always fit.
        _ = self.set(.serial, s.serial);
        _ = self.set(.prefix, s.prefix);
        _ = self.set(.exe, s.exe);
        _ = self.set(.capture_dir, s.capture_dir);
        self.autolaunch = s.autolaunch;
        self.clearErrors();
        self.checkPaths();
    }

    /// Defaults of `client.Settings` (same as config.Settings in the daemon).
    pub fn loadDefaults(self: *Form) void {
        self.load(.{});
    }

    pub fn toSettings(self: *const Form) client.Settings {
        return .{
            .serial = self.get(.serial),
            .prefix = self.get(.prefix),
            .exe = self.get(.exe),
            .capture_dir = self.get(.capture_dir),
            .autolaunch = self.autolaunch,
        };
    }

    pub const Changes = struct {
        serial: bool,
        prefix: bool,
        exe: bool,
        capture_dir: bool,
        autolaunch: bool,

        pub fn any(self: Changes) bool {
            return self.serial or self.prefix or self.exe or self.capture_dir or self.autolaunch;
        }

        /// Changes that reset the live connection (unit or Wine prefix).
        pub fn touchesConnection(self: Changes) bool {
            return self.serial or self.prefix;
        }
    };

    pub fn changesFrom(self: *const Form, s: client.Settings) Changes {
        return .{
            .serial = !std.mem.eql(u8, self.get(.serial), s.serial),
            .prefix = !std.mem.eql(u8, self.get(.prefix), s.prefix),
            .exe = !std.mem.eql(u8, self.get(.exe), s.exe),
            .capture_dir = !std.mem.eql(u8, self.get(.capture_dir), s.capture_dir),
            .autolaunch = self.autolaunch != s.autolaunch,
        };
    }

    /// Fill `errors` for every invalid field. True when the whole form is valid.
    pub fn validate(self: *Form) bool {
        self.clearErrors();
        self.setError(.serial, serialProblem(self.get(.serial)));
        self.setError(.prefix, pathProblem(self.get(.prefix)));
        self.setError(.exe, exeProblem(self.get(.exe)));
        self.setError(.capture_dir, pathProblem(self.get(.capture_dir)));
        for (self.errors) |e| if (e != null) return false;
        return true;
    }

    /// Map the daemon's rejection reason to a field. False if it names none.
    pub fn applyServerReason(self: *Form, reason: []const u8) bool {
        const map = .{
            .{ "invalid serial", Field.serial },
            .{ "invalid prefix", Field.prefix },
            .{ "invalid exe", Field.exe },
            .{ "invalid capture_dir", Field.capture_dir },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, reason, entry[0])) {
                self.setError(entry[1], "diveZ did not accept this value.");
                return true;
            }
        }
        return false;
    }
};

pub fn serialProblem(v: []const u8) ?[]const u8 {
    if (config.validSerial(v)) return null;
    return "Choose “Automatic” or a unit under /dev (for example /dev/ttyUSB0).";
}

/// Wine prefix and capture folder: empty (default) or an absolute path.
pub fn pathProblem(v: []const u8) ?[]const u8 {
    if (config.validPrefix(v)) return null;
    if (v.len >= max_text - 1) return "The path is too long.";
    if (v[0] != '/') return "Must be an absolute path (starts with /).";
    if (std.mem.indexOf(u8, v, "..") != null) return "Cannot contain “..”.";
    return "Contains invalid characters.";
}

pub fn exeProblem(v: []const u8) ?[]const u8 {
    if (config.validExe(v)) return null;
    if (v.len >= max_text - 1) return "The path is too long.";
    return "Contains invalid characters.";
}

fn kindOf(path: []const u8) ?std.fs.File.Kind {
    // statFile does not open the node, so device files are safe to look at.
    const st = std.fs.cwd().statFile(path) catch return null;
    return st.kind;
}

/// Only absolute paths are checked: Windows-style paths (C:\\...) only mean something to Wine.
fn isLocalPath(v: []const u8) bool {
    return v.len > 0 and v[0] == '/';
}

pub fn serialWarning(v: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, v, "/dev/")) return null; // "auto" or invalid (reported as an error)
    if (kindOf(v) == null) return "That unit is not connected right now; it will be used when it appears.";
    return null;
}

pub fn prefixWarning(v: []const u8) ?[]const u8 {
    if (!isLocalPath(v)) return null;
    const k = kindOf(v) orelse return "That folder does not exist yet: Wine will create a new, empty prefix with no Diver-Office installed.";
    if (k != .directory) return "That path is not a folder.";
    return null;
}

pub fn exeWarning(v: []const u8) ?[]const u8 {
    if (!isLocalPath(v)) return null;
    const k = kindOf(v) orelse return "That file cannot be found.";
    if (k == .directory) return "That path is a folder, not a program.";
    return null;
}

/// A missing capture folder is fine (the daemon creates it); one that is a file is not.
pub fn captureWarning(v: []const u8) ?[]const u8 {
    if (!isLocalPath(v)) return null;
    const k = kindOf(v) orelse return null;
    if (k != .directory) return "That path exists but is not a folder.";
    return null;
}

test "path warnings look at the real file system" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("wine");
    try tmp.dir.writeFile(.{ .sub_path = "diver.exe", .data = "" });
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const a = std.testing.allocator;
    const dir = try std.fmt.allocPrint(a, "{s}/wine", .{base});
    defer a.free(dir);
    const file = try std.fmt.allocPrint(a, "{s}/diver.exe", .{base});
    defer a.free(file);
    const missing = try std.fmt.allocPrint(a, "{s}/nope", .{base});
    defer a.free(missing);

    try std.testing.expect(prefixWarning(dir) == null);
    try std.testing.expect(prefixWarning(missing) != null);
    try std.testing.expect(prefixWarning(file) != null); // a file is not a prefix
    try std.testing.expect(exeWarning(file) == null);
    try std.testing.expect(exeWarning(missing) != null);
    try std.testing.expect(exeWarning(dir) != null);
    try std.testing.expect(captureWarning(missing) == null); // will be created
    try std.testing.expect(captureWarning(file) != null);
    try std.testing.expect(captureWarning(dir) == null);
    // Not checked: empty, relative, Windows style, "auto".
    try std.testing.expect(prefixWarning("") == null and exeWarning("C:\\x\\a.exe") == null);
    try std.testing.expect(serialWarning("auto") == null);
    try std.testing.expect(serialWarning("/dev/ttyUSB-no-such-unit") != null);
    try std.testing.expect(serialWarning("/dev/null") == null);
}

test "load refreshes the warnings" {
    var f = Form{};
    f.load(.{ .prefix = "/definitely/not/here" });
    try std.testing.expect(f.warningOf(.prefix) != null);
    f.loadDefaults();
    try std.testing.expect(f.warningOf(.prefix) == null);
}

test "set and get round trip, and refuse oversized values" {
    var f = Form{};
    try std.testing.expect(f.set(.prefix, "/home/u/.wine"));
    try std.testing.expectEqualStrings("/home/u/.wine", f.get(.prefix));
    try std.testing.expect(f.set(.prefix, "/x")); // shorter value must not leave old bytes behind
    try std.testing.expectEqualStrings("/x", f.get(.prefix));
    const long = "/" ++ "a" ** 400;
    try std.testing.expect(!f.set(.prefix, long));
    try std.testing.expectEqualStrings("/x", f.get(.prefix));
}

test "load, toSettings and defaults" {
    var f = Form{};
    f.load(.{ .serial = "/dev/ttyUSB1", .prefix = "/w", .exe = "C:\\a.exe", .capture_dir = "/c", .autolaunch = false });
    const s = f.toSettings();
    try std.testing.expectEqualStrings("/dev/ttyUSB1", s.serial);
    try std.testing.expectEqualStrings("C:\\a.exe", s.exe);
    try std.testing.expect(!s.autolaunch);
    f.loadDefaults();
    try std.testing.expectEqualStrings("auto", f.get(.serial));
    try std.testing.expectEqualStrings("", f.get(.prefix));
    try std.testing.expect(f.autolaunch);
}

test "changes and connection impact" {
    var f = Form{};
    const base = client.Settings{ .prefix = "/w" };
    f.load(base);
    try std.testing.expect(!f.changesFrom(base).any());
    _ = f.set(.capture_dir, "/c");
    var ch = f.changesFrom(base);
    try std.testing.expect(ch.any() and ch.capture_dir and !ch.touchesConnection());
    _ = f.set(.prefix, "/other");
    ch = f.changesFrom(base);
    try std.testing.expect(ch.touchesConnection());
}

test "validation messages" {
    var f = Form{};
    f.loadDefaults();
    try std.testing.expect(f.validate());
    _ = f.set(.prefix, "relative/dir");
    _ = f.set(.capture_dir, "/home/../etc");
    _ = f.set(.serial, "/etc/passwd");
    try std.testing.expect(!f.validate());
    try std.testing.expect(f.errorOf(.prefix) != null);
    try std.testing.expectEqualStrings("Must be an absolute path (starts with /).", f.errorOf(.prefix).?);
    try std.testing.expectEqualStrings("Cannot contain “..”.", f.errorOf(.capture_dir).?);
    try std.testing.expect(f.errorOf(.serial) != null);
    try std.testing.expect(f.errorOf(.exe) == null);
}

test "daemon rejection reason lands on its field" {
    var f = Form{};
    try std.testing.expect(f.applyServerReason("invalid prefix"));
    try std.testing.expect(f.errorOf(.prefix) != null);
    try std.testing.expect(!f.applyServerReason("bad json"));
}

test "setField picks the field at run time" {
    var f = Form{};
    try std.testing.expect(f.setField(.exe, "C:\\a.exe"));
    try std.testing.expectEqualStrings("C:\\a.exe", f.get(.exe));
    try std.testing.expectEqualStrings("", f.get(.prefix));
}
