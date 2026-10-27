//! Background runner: one worker thread executes jobs one at a time so the UI thread
//! never waits on a socket or a native dialog. Generic over the job and result types so
//! it can be tested without DVUI. Both types need `pub fn deinit(*@This(), Allocator) void`.
const std = @import("std");

pub fn Runner(comptime Job: type, comptime Result: type) type {
    return struct {
        const Self = @This();
        /// Runs on the worker thread. Borrows `job` (the runner frees it afterwards).
        pub const ExecFn = *const fn (std.mem.Allocator, Job) Result;
        /// Called from the worker thread after a result is queued, to wake the UI.
        pub const WakeFn = *const fn (?*anyopaque) void;

        gpa: std.mem.Allocator,
        exec: ExecFn,
        wake: ?WakeFn = null,
        wake_ctx: ?*anyopaque = null,

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        jobs: std.ArrayListUnmanaged(Job) = .{},
        results: std.ArrayListUnmanaged(Result) = .{},
        stopping: bool = false,
        /// True while the worker is executing a job (set and cleared under `mutex`).
        running: bool = false,
        thread: ?std.Thread = null,

        pub fn start(self: *Self) !void {
            self.thread = try std.Thread.spawn(.{}, loop, .{self});
        }

        /// Queue a job. The runner owns it from here on, even if this fails.
        pub fn submit(self: *Self, job: Job) !void {
            var j = job;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) {
                j.deinit(self.gpa);
                return error.Stopped;
            }
            self.jobs.append(self.gpa, j) catch |err| {
                j.deinit(self.gpa);
                return err;
            };
            self.cond.signal();
        }

        /// Oldest finished result, or null. The caller owns it.
        pub fn nextResult(self: *Self) ?Result {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.results.items.len == 0) return null;
            return self.results.orderedRemove(0);
        }

        /// True when a finished result is waiting to be taken. The UI loop asks this right before
        /// it goes to sleep: a job that finished (and sent its wake-up) while the loop was busy
        /// would otherwise be forgotten until the next input event.
        pub fn hasResult(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.results.items.len > 0;
        }

        /// Finish the job in progress, drop the queued ones and join the thread.
        pub fn stop(self: *Self) void {
            self.mutex.lock();
            self.stopping = true;
            for (self.jobs.items) |*j| j.deinit(self.gpa);
            self.jobs.clearRetainingCapacity();
            self.cond.signal();
            self.mutex.unlock();
            if (self.thread) |t| t.join();
            self.thread = null;
        }

        /// Like `stop`, but gives up without joining if the job in progress does not finish
        /// within `timeout_ms` (a file dialog the user left open, say). False means the worker
        /// thread is still running: the caller must not free anything it may touch, and should
        /// just exit the process.
        pub fn stopWithin(self: *Self, timeout_ms: i64) bool {
            self.mutex.lock();
            self.stopping = true;
            for (self.jobs.items) |*j| j.deinit(self.gpa);
            self.jobs.clearRetainingCapacity();
            self.cond.signal();
            self.mutex.unlock();

            const deadline = std.time.milliTimestamp() + timeout_ms;
            while (true) {
                self.mutex.lock();
                const busy = self.running;
                self.mutex.unlock();
                if (!busy) break;
                if (std.time.milliTimestamp() >= deadline) return false;
                std.time.sleep(2 * std.time.ns_per_ms);
            }
            if (self.thread) |t| t.join();
            self.thread = null;
            return true;
        }

        /// Stops if needed and frees whatever is left over.
        pub fn deinit(self: *Self) void {
            self.stop();
            for (self.results.items) |*r| r.deinit(self.gpa);
            self.results.deinit(self.gpa);
            self.jobs.deinit(self.gpa);
        }

        fn loop(self: *Self) void {
            while (true) {
                self.mutex.lock();
                while (self.jobs.items.len == 0 and !self.stopping) self.cond.wait(&self.mutex);
                if (self.stopping) {
                    self.mutex.unlock();
                    return;
                }
                var job = self.jobs.orderedRemove(0);
                self.running = true;
                self.mutex.unlock();

                var result = self.exec(self.gpa, job);
                job.deinit(self.gpa);

                self.mutex.lock();
                self.results.append(self.gpa, result) catch result.deinit(self.gpa);
                self.running = false;
                self.mutex.unlock();
                if (self.wake) |w| w(self.wake_ctx);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TJob = struct {
    n: u32,
    buf: []u8, // owned, so the tests catch any path that forgets to free
    pub fn deinit(self: *TJob, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
    }
};
const TResult = struct {
    n: u32,
    buf: []u8,
    pub fn deinit(self: *TResult, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
    }
};

fn slowDouble(gpa: std.mem.Allocator, job: TJob) TResult {
    std.time.sleep(5 * std.time.ns_per_ms);
    return .{ .n = job.n * 2, .buf = gpa.dupe(u8, job.buf) catch @panic("oom") };
}

fn countWake(ctx: ?*anyopaque) void {
    const c: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = c.fetchAdd(1, .seq_cst);
}

fn newJob(gpa: std.mem.Allocator, n: u32) !TJob {
    return .{ .n = n, .buf = try gpa.dupe(u8, "payload") };
}

test "jobs run in order off the calling thread and wake the UI" {
    const gpa = std.testing.allocator;
    var wakes = std.atomic.Value(u32).init(0);
    var r = Runner(TJob, TResult){ .gpa = gpa, .exec = slowDouble, .wake = countWake, .wake_ctx = &wakes };
    try r.start();
    defer r.deinit();

    for ([_]u32{ 1, 2, 3 }) |n| try r.submit(try newJob(gpa, n));

    var got: [3]u32 = undefined;
    var count: usize = 0;
    var tries: usize = 0;
    while (count < 3 and tries < 400) : (tries += 1) {
        if (r.nextResult()) |res| {
            var x = res;
            got[count] = x.n;
            count += 1;
            x.deinit(gpa);
        } else std.time.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, &got);
    try std.testing.expectEqual(@as(u32, 3), wakes.load(.seq_cst));
}

test "stop drops queued jobs and nothing leaks" {
    const gpa = std.testing.allocator;
    var r = Runner(TJob, TResult){ .gpa = gpa, .exec = slowDouble };
    try r.start();
    for (0..20) |i| try r.submit(try newJob(gpa, @intCast(i)));
    r.deinit(); // finished-but-unread results and queued jobs are freed here
}

test "submit after stop is refused and frees the job" {
    const gpa = std.testing.allocator;
    var r = Runner(TJob, TResult){ .gpa = gpa, .exec = slowDouble };
    try r.start();
    r.stop();
    try std.testing.expectError(error.Stopped, r.submit(try newJob(gpa, 1)));
    r.deinit();
}

fn verySlow(gpa: std.mem.Allocator, job: TJob) TResult {
    std.time.sleep(300 * std.time.ns_per_ms);
    return .{ .n = job.n, .buf = gpa.dupe(u8, job.buf) catch @panic("oom") };
}

test "stopWithin gives up on a stuck job, then a normal stop finishes cleanly" {
    const gpa = std.testing.allocator;
    var r = Runner(TJob, TResult){ .gpa = gpa, .exec = verySlow };
    try r.start();
    try r.submit(try newJob(gpa, 1));
    std.time.sleep(30 * std.time.ns_per_ms); // let the worker pick it up
    try std.testing.expect(!r.stopWithin(20)); // still sleeping: gives up without joining
    r.deinit(); // joins once the job is done and frees its result
}

test "stopWithin returns true when nothing is stuck" {
    const gpa = std.testing.allocator;
    var r = Runner(TJob, TResult){ .gpa = gpa, .exec = slowDouble };
    try r.start();
    try r.submit(try newJob(gpa, 1));
    try std.testing.expect(r.stopWithin(3000));
    r.deinit();
}

test "hasResult is true from the moment a result is queued until it is taken" {
    const gpa = std.testing.allocator;
    var r = Runner(TJob, TResult){ .gpa = gpa, .exec = slowDouble };
    try r.start();
    try std.testing.expect(!r.hasResult());
    try r.submit(try newJob(gpa, 7));
    var tries: usize = 0;
    while (!r.hasResult() and tries < 400) : (tries += 1) std.time.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(r.hasResult());
    var res = r.nextResult().?;
    res.deinit(gpa);
    try std.testing.expect(!r.hasResult());
    r.deinit();
}
