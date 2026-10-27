//! Tap: the observation hook for the bridge.
//!
//! Every chunk crossing the bridge is passed to `Tap.onChunk` *after* the
//! forwarding decision has been made, so a bug here can never corrupt or stall
//! the live byte stream. Errors are logged and the failing sink is disabled;
//! they are never propagated to the bridge.
//!
//! Two sinks are provided:
//!   1. Frame log  (`frames-<unix>.bin`): lossless, timestamped record of both
//!      directions. Use it to develop and test the parser offline.
//!   2. MonReconstructor: the integration point for diveRlib-derived logic.

const std = @import("std");

pub const Direction = enum(u8) {
    /// Bytes written by Diver-Office (Wine) towards the physical unit.
    host_to_device = 0,
    /// Bytes produced by the physical unit towards Diver-Office.
    device_to_host = 1,
};

/// Frame log record layout (little endian), repeated until EOF:
///   u64 timestamp_us (unix epoch) | u8 direction | u32 payload_len | payload
pub const frame_header_len = 13;

pub const Tap = struct {
    dir: ?std.fs.Dir = null,
    capture: ?std.fs.File = null,
    mon: MonReconstructor = .{},

    pub fn init(capture_dir: ?[]const u8) !Tap {
        var self = Tap{};
        const path = capture_dir orelse return self;

        try std.fs.cwd().makePath(path);
        var dir = try std.fs.cwd().openDir(path, .{});
        errdefer dir.close();

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "frames-{d}.bin", .{std.time.timestamp()});
        self.capture = try dir.createFile(name, .{});
        self.dir = dir;
        self.mon.dir = dir;
        return self;
    }

    pub fn deinit(self: *Tap) void {
        self.mon.endSession();
        if (self.capture) |f| f.close();
        if (self.dir) |*d| d.close();
        self.* = .{};
    }

    /// Called for every chunk that crosses the bridge, in arrival order.
    pub fn onChunk(self: *Tap, direction: Direction, bytes: []const u8) void {
        self.recordFrame(direction, bytes) catch |err| {
            std.log.err("tap: frame log disabled after error: {s}", .{@errorName(err)});
            if (self.capture) |f| f.close();
            self.capture = null;
        };
        self.mon.feed(direction, bytes) catch |err| {
            std.log.err("tap: .MON reconstructor disabled after error: {s}", .{@errorName(err)});
            self.mon.disabled = true;
            self.mon.endSession();
        };
    }

    /// Called when the physical link goes up or down, so the reconstructor can
    /// finalize a partial file and never splice two transfers together.
    pub fn sessionBoundary(self: *Tap) void {
        self.mon.endSession();
    }

    fn recordFrame(self: *Tap, direction: Direction, bytes: []const u8) !void {
        const f = self.capture orelse return;
        var hdr: [frame_header_len]u8 = undefined;
        std.mem.writeInt(u64, hdr[0..8], @intCast(std.time.microTimestamp()), .little);
        hdr[8] = @intFromEnum(direction);
        std.mem.writeInt(u32, hdr[9..13], @intCast(bytes.len), .little);
        try f.writeAll(&hdr);
        try f.writeAll(bytes);
    }
};

/// ===========================================================================
/// HOOK BOUNDARY: diveRlib integration point.
///
/// `feed` receives the full, ordered, bidirectional stream. The default
/// implementation only persists the device->host stream verbatim into
/// `session-<unix>.raw`; it does NOT produce a valid .MON file. Replace the
/// body with the framing / state machine ported from diveRlib:
///   * track host->device commands to know which response is expected,
///   * delimit and validate device->host frames (length/checksum as per the
///     protocol you recover from the frame logs),
///   * emit header + sample records into the .MON layout.
/// Develop it offline against `frames-*.bin` before wiring it in live.
/// ===========================================================================
pub const MonReconstructor = struct {
    dir: ?std.fs.Dir = null,
    out: ?std.fs.File = null,
    bytes_written: u64 = 0,
    disabled: bool = false,

    pub fn feed(self: *MonReconstructor, direction: Direction, bytes: []const u8) !void {
        if (self.disabled) return;
        const dir = self.dir orelse return;

        // TODO(diveRlib): protocol-aware parsing replaces everything below.
        if (direction != .device_to_host) return;
        if (self.out == null) {
            var name_buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "session-{d}.raw", .{std.time.timestamp()});
            self.out = try dir.createFile(name, .{});
            self.bytes_written = 0;
        }
        try self.out.?.writeAll(bytes);
        self.bytes_written += bytes.len;
    }

    /// Finalize the current transfer (rename, fsync, write trailer, ...).
    pub fn endSession(self: *MonReconstructor) void {
        if (self.out) |f| {
            f.sync() catch {};
            f.close();
            std.log.info("tap: session closed ({d} device bytes)", .{self.bytes_written});
        }
        self.out = null;
    }
};

test "frame header layout" {
    var hdr: [frame_header_len]u8 = undefined;
    std.mem.writeInt(u32, hdr[9..13], 0xAABBCCDD, .little);
    try std.testing.expectEqual(@as(u8, 0xDD), hdr[9]);
    try std.testing.expectEqual(@as(u8, 0xAA), hdr[12]);
}
