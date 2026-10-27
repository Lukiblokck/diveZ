//! What the window knows about the daemon: the latest status, or why there is none.
//! Requests run on the worker thread; this module only submits them and applies results.
const std = @import("std");
const client = @import("client.zig");
const texts = @import("texts.zig");
const worker = @import("worker.zig");

/// Failed polls in a row tolerated (slow or briefly unreachable daemon) while the last good
/// status is still shown.
const max_tolerated_failures = 3;
/// After starting the daemon, how long "starting…" is shown instead of an error.
const start_grace_ms = 12_000;
/// A window opened just as the daemon starts may see its files half written.
const early_grace_ms = 5_000;

pub const Model = struct {
    gpa: std.mem.Allocator,
    runner: *worker.Runner,
    /// Latest status; its strings belong to the snapshot.
    snapshot: ?client.Snapshot = null,
    /// Shown when `snapshot` is null.
    problem: []const u8 = texts.connecting,
    /// Why there is no status (for the buttons offered under `problem`).
    last_error: ?anyerror = null,
    /// One line of diagnostics to read out when asking for help; filled for real problems.
    detail_buf: [320]u8 = undefined,
    detail: []const u8 = "",
    /// Start diveZ by itself, once, if the window opens and finds it not running. Never again
    /// after that: a user who quit it on purpose does not want it back.
    auto_start: bool = true,
    /// A start job is queued or running.
    starting: bool = false,
    start_grace_until_ms: i64 = 0,
    opened_ms: i64 = 0,
    /// Static text: why the last start failed.
    start_error: ?[]const u8 = null,
    last_poll_ms: i64 = 0,
    poll_in_flight: bool = false,
    /// Consecutive failed polls while the last good status is still shown.
    failed_polls: u8 = 0,
    /// Finished jobs other than status polls, waiting for the screens to handle them.
    finished: std.ArrayListUnmanaged(worker.Result) = .{},

    pub fn deinit(self: *Model) void {
        self.clear();
        for (self.finished.items) |*r| r.deinit(self.gpa);
        self.finished.deinit(self.gpa);
    }

    fn clear(self: *Model) void {
        if (self.snapshot) |*s| s.deinit();
        self.snapshot = null;
    }

    /// The daemon is slow to answer: the status on screen is the last good one.
    pub fn unresponsive(self: *const Model) bool {
        return self.failed_polls > 0;
    }

    /// "Starting diveZ…" is on screen: a start job is running or the daemon is still coming up.
    pub fn isStarting(self: *const Model) bool {
        return self.starting or std.time.milliTimestamp() < self.start_grace_until_ms;
    }

    /// Start the daemon in the background (`restart` first stops a stuck one).
    pub fn startDaemon(self: *Model, restart: bool) void {
        if (self.starting) return;
        self.auto_start = false; // this was a decision; do not repeat it by itself
        self.start_error = null;
        if (!self.submit(.{ .start_daemon = .{ .restart = restart } })) {
            self.start_error = texts.requestFailure(error.OutOfMemory);
            return;
        }
        self.starting = true;
    }

    /// Ask for a new status as soon as none is in flight (after an action changed something).
    pub fn refreshNow(self: *Model) void {
        self.last_poll_ms = 0;
    }

    /// Queue a job. False (and the job freed) if it could not be queued.
    pub fn submit(self: *Model, job: worker.Job) bool {
        self.runner.submit(job) catch return false;
        return true;
    }

    /// Start a status poll if one is due and none is running.
    pub fn pollIfDue(self: *Model, interval_ms: i64) void {
        if (self.poll_in_flight) return;
        const now = std.time.milliTimestamp();
        if (self.opened_ms == 0) self.opened_ms = now;
        if (now - self.last_poll_ms < interval_ms) return;
        if (!self.submit(.status)) return; // try again on the next frame
        self.last_poll_ms = now;
        self.poll_in_flight = true;
    }

    /// Collect what the worker finished: status results are applied here, the rest is queued
    /// for `nextFinished`.
    pub fn update(self: *Model) void {
        while (self.runner.nextResult()) |res| {
            switch (res) {
                .status => |done| self.applyStatus(done),
                .start => |done| self.applyStart(done),
                else => {
                    var r = res;
                    self.finished.append(self.gpa, r) catch r.deinit(self.gpa);
                },
            }
        }
    }

    pub fn nextFinished(self: *Model) ?worker.Result {
        if (self.finished.items.len == 0) return null;
        return self.finished.orderedRemove(0);
    }

    fn applyStart(self: *Model, done: worker.StartDone) void {
        self.starting = false;
        switch (done) {
            .ok => {
                self.start_grace_until_ms = std.time.milliTimestamp() + start_grace_ms;
                self.refreshNow();
            },
            .err => |err| self.start_error = texts.startFailure(err),
        }
    }

    fn applyStatus(self: *Model, done: worker.Done(client.Snapshot)) void {
        self.poll_in_flight = false;
        const was_online = self.snapshot != null;
        switch (done) {
            .ok => |snap| {
                self.clear();
                self.failed_polls = 0;
                self.snapshot = snap;
                self.last_error = null;
                self.detail = "";
                self.auto_start = false; // it was already running: never start another by itself
                self.start_error = null;
                self.start_grace_until_ms = 0;
                if (!was_online) std.log.info("connected to diveZ v{s}", .{snap.value.version});
            },
            .err => |err| {
                // A slow or briefly unreachable daemon is not a missing one: keep showing the
                // last status for a few polls. "No process" shows at once.
                const transient = err == error.Timeout or err == error.ConnectionLost or err == error.Unauthorized;
                if (was_online and transient and self.failed_polls < max_tolerated_failures) {
                    self.failed_polls += 1;
                    return;
                }
                self.clear();
                self.failed_polls = 0;
                self.last_error = err;
                if (err == error.DaemonNotRunning and self.auto_start and !self.starting) self.startDaemon(false);

                const now = std.time.milliTimestamp();
                const early = now - self.opened_ms < early_grace_ms;
                if (self.isStarting()) {
                    self.problem = texts.starting;
                    self.detail = "";
                } else if (early and err == error.DaemonUnreachable) {
                    self.problem = texts.connecting; // the daemon may be writing its files right now
                    self.detail = "";
                } else {
                    self.problem = texts.requestFailure(err);
                    self.detail = client.diagnose(&self.detail_buf);
                }
                if (was_online) std.log.info("lost connection to diveZ: {s}", .{@errorName(err)});
            },
        }
    }

    /// A finished job is waiting for `update`: the loop must not go to sleep yet.
    pub fn hasPendingResults(self: *Model) bool {
        return self.runner.hasResult();
    }

    /// Microseconds until the next poll is due, for the event wait timeout. While a poll is
    /// running its result wakes the window, so there is nothing to wait for.
    pub fn untilNextPollMicros(self: *const Model, interval_ms: i64) u32 {
        // Never sleep longer than a second, even with a poll in flight: if a wake-up is ever
        // missed, the window is at most one second stale instead of until the next input event.
        if (self.poll_in_flight) return 1_000_000;
        const due_ms: i64 = @max(0, self.last_poll_ms + interval_ms - std.time.milliTimestamp());
        return @intCast(due_ms * 1000);
    }
};
