//! The concrete jobs the window runs in the background, and how each one executes.
const std = @import("std");
const dvui = @import("dvui");
const client = @import("client.zig");
const form = @import("form.zig");
const jobs = @import("jobs.zig");

pub const PickKind = enum { folder, file };

pub const Pick = struct {
    kind: PickKind,
    field: form.Field,
    title: []const u8, // owned
    start: ?[]const u8, // owned
};

pub const Job = union(enum) {
    /// GET /api/status
    status,
    /// GET /api/detect
    detect,
    action: client.Action,
    /// Owned JSON body for POST /api/config.
    save: []const u8,
    /// Native file or folder dialog (blocks the worker, not the window).
    pick: Pick,
    /// Start the daemon in the background; `restart` first stops one that is stuck.
    start_daemon: struct { restart: bool },

    pub fn deinit(self: *Job, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .save => |body| gpa.free(body),
            .pick => |p| {
                gpa.free(p.title);
                if (p.start) |s| gpa.free(s);
            },
            else => {},
        }
    }
};

/// Outcome of a request: the parsed reply, or why it failed.
pub fn Done(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: anyerror,

        pub fn deinit(self: *@This()) void {
            if (self.* == .ok) self.ok.deinit();
        }
    };
}

/// Outcome of starting the daemon (nothing to free).
pub const StartDone = union(enum) { ok, err: anyerror };

pub const Result = union(enum) {
    status: Done(client.Snapshot),
    detect: Done(client.DetectSnapshot),
    action: struct { action: client.Action, outcome: Done(client.Outcome) },
    save: Done(client.ConfigOutcome),
    /// `path` is owned; null when the dialog was cancelled or unavailable.
    pick: struct { field: form.Field, path: ?[]const u8 },
    start: StartDone,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .status => |*d| d.deinit(),
            .detect => |*d| d.deinit(),
            .action => |*a| a.outcome.deinit(),
            .save => |*d| d.deinit(),
            .pick => |p| if (p.path) |path| gpa.free(path),
            .start => {},
        }
    }
};

pub const Runner = jobs.Runner(Job, Result);

fn done(comptime T: type, r: anytype) Done(T) {
    return if (r) |v| .{ .ok = v } else |e| .{ .err = e };
}

/// Runs on the worker thread.
pub fn execute(gpa: std.mem.Allocator, job: Job) Result {
    return switch (job) {
        .status => .{ .status = done(client.Snapshot, client.fetchStatus(gpa)) },
        .detect => .{ .detect = done(client.DetectSnapshot, client.fetchDetect(gpa)) },
        .action => |a| .{ .action = .{ .action = a, .outcome = done(client.Outcome, client.runAction(gpa, a)) } },
        .save => |body| .{ .save = done(client.ConfigOutcome, client.saveConfigBody(gpa, body)) },
        .pick => |p| .{ .pick = .{ .field = p.field, .path = pickPath(gpa, p) } },
        .start_daemon => |s| .{ .start = runStart(gpa, s.restart) },
    };
}

fn runStart(gpa: std.mem.Allocator, restart: bool) StartDone {
    if (restart and !client.stopDaemon()) return .{ .err = error.StopFailed };
    client.startDaemon(gpa) catch |e| return .{ .err = e };
    return .ok;
}

fn pickPath(gpa: std.mem.Allocator, p: Pick) ?[]const u8 {
    return switch (p.kind) {
        .folder => dvui.dialogNativeFolderSelect(gpa, .{ .title = p.title, .path = p.start }) catch null,
        .file => dvui.dialogNativeFileOpen(gpa, .{
            .title = p.title,
            .path = p.start,
            .filters = &[_][]const u8{ "*.exe", "*.EXE" },
            .filter_description = "Windows programs (*.exe)",
        }) catch null,
    };
}
