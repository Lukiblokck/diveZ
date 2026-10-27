//! Terminal layer: pty creation, raw termios configuration and errno-exact I/O.
//!
//! libc's termios is bound via @cImport on purpose: the flag representation in
//! `std.posix.termios` has changed between Zig releases, the libc ABI has not.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("stdlib.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
});

pub const TermError = error{
    TcGetAttr,
    TcSetAttr,
    SetSpeed,
    GrantPt,
    UnlockPt,
    PtsName,
    UnsupportedSpeed,
};

const speed_table = [_]struct { baud: u32, speed: c.speed_t }{
    .{ .baud = 1200, .speed = c.B1200 },
    .{ .baud = 2400, .speed = c.B2400 },
    .{ .baud = 4800, .speed = c.B4800 },
    .{ .baud = 9600, .speed = c.B9600 },
    .{ .baud = 19200, .speed = c.B19200 },
    .{ .baud = 38400, .speed = c.B38400 },
    .{ .baud = 57600, .speed = c.B57600 },
    .{ .baud = 115200, .speed = c.B115200 },
};

pub fn speedFromBaud(baud: u32) ?c.speed_t {
    for (speed_table) |e| if (e.baud == baud) return e.speed;
    return null;
}

pub fn baudFromSpeed(speed: c.speed_t) ?u32 {
    for (speed_table) |e| if (e.speed == speed) return e.baud;
    return null;
}

/// The subset of line settings we mirror from Wine's pty to the real port.
pub const LineParams = struct {
    speed: c.speed_t,
    /// Subset of c_cflag: CSIZE | CSTOPB | PARENB | PARODD. Defaults to 8N1.
    frame: c.tcflag_t = c.CS8,

    pub const frame_mask: c.tcflag_t = c.CSIZE | c.CSTOPB | c.PARENB | c.PARODD;

    pub fn eql(a: LineParams, b: LineParams) bool {
        return a.speed == b.speed and a.frame == b.frame;
    }

    /// Human readable form, e.g. "9600 8N1". `buf` should be >= 16 bytes.
    pub fn describe(self: LineParams, buf: []u8) []const u8 {
        const baud = baudFromSpeed(self.speed) orelse 0;
        const bits: u8 = switch (self.frame & c.CSIZE) {
            c.CS5 => 5,
            c.CS6 => 6,
            c.CS7 => 7,
            else => 8,
        };
        const parity: u8 = if (self.frame & c.PARENB == 0) 'N' else if (self.frame & c.PARODD != 0) 'O' else 'E';
        const stop: u8 = if (self.frame & c.CSTOPB != 0) 2 else 1;
        return std.fmt.bufPrint(buf, "{d} {d}{c}{d}", .{ baud, bits, parity, stop }) catch "?";
    }
};

/// CRTSCTS is 1<<31 on every Linux architecture, but translate-c types the
/// macro as c_int, where it overflows. Define it explicitly.
const crtscts: c.tcflag_t = @as(c.tcflag_t, 1) << 31;

/// Put `fd` into strict raw mode (no echo, no canonical mode, no signals, no
/// output post-processing, no software or hardware flow control) with the
/// given speed and frame format.
pub fn applyRaw(fd: posix.fd_t, p: LineParams) TermError!void {
    var tio: c.termios = undefined;
    if (c.tcgetattr(fd, &tio) != 0) return error.TcGetAttr;

    c.cfmakeraw(&tio);
    tio.c_cflag &= ~@as(c.tcflag_t, c.CSIZE | c.CSTOPB | c.PARENB | c.PARODD) & ~crtscts;
    tio.c_cflag |= p.frame | c.CLOCAL | c.CREAD;
    tio.c_iflag &= ~@as(c.tcflag_t, c.IXON | c.IXOFF | c.IXANY);
    // Non-blocking semantics; readiness is driven by poll().
    tio.c_cc[c.VMIN] = 0;
    tio.c_cc[c.VTIME] = 0;

    if (c.cfsetispeed(&tio, p.speed) != 0 or c.cfsetospeed(&tio, p.speed) != 0)
        return error.SetSpeed;
    if (c.tcsetattr(fd, c.TCSANOW, &tio) != 0) return error.TcSetAttr;
}

/// Read the current line parameters of `fd`. Fails with `UnsupportedSpeed` for
/// B0 or non-table (BOTHER) speeds, in which case the caller keeps its previous value.
pub fn readParams(fd: posix.fd_t) TermError!LineParams {
    var tio: c.termios = undefined;
    if (c.tcgetattr(fd, &tio) != 0) return error.TcGetAttr;
    const speed = c.cfgetospeed(&tio);
    if (speed == c.B0 or baudFromSpeed(speed) == null) return error.UnsupportedSpeed;
    return .{ .speed = speed, .frame = tio.c_cflag & LineParams.frame_mask };
}

/// Open the physical serial node: non-blocking, no controlling tty, exclusive.
pub fn openSerial(path: [:0]const u8) !posix.fd_t {
    const fd = try posix.openZ(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true }, 0);
    // Best effort: keep other processes from opening the node concurrently.
    _ = c.ioctl(fd, c.TIOCEXCL);
    return fd;
}

/// Assert DTR+RTS on the physical port. Some reader interfaces draw power or
/// enable their level shifters from these lines. A pty cannot forward line
/// changes made by Wine, so we assert them statically.
pub fn assertDtrRts(fd: posix.fd_t) void {
    var bits: c_int = c.TIOCM_DTR | c.TIOCM_RTS;
    _ = c.ioctl(fd, c.TIOCMBIS, &bits);
}

/// Pseudoterminal pair used as the Wine-facing endpoint.
pub const Pty = struct {
    master: posix.fd_t,
    /// Slave fd held open by the daemon so the master never sees POLLHUP while
    /// Wine is not connected, and so we can query the slave's termios at will.
    keepalive: posix.fd_t,
    path_buf: [64]u8 = undefined,
    path_len: usize = 0,

    pub fn open(initial: LineParams) !Pty {
        const master = try posix.openZ("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true }, 0);
        errdefer posix.close(master);

        if (c.grantpt(master) != 0) return error.GrantPt;
        if (c.unlockpt(master) != 0) return error.UnlockPt;

        var self = Pty{ .master = master, .keepalive = -1 };
        if (c.ptsname_r(master, &self.path_buf, self.path_buf.len) != 0) return error.PtsName;
        self.path_len = std.mem.indexOfScalar(u8, &self.path_buf, 0) orelse return error.PtsName;

        const slave_z: [:0]const u8 = self.path_buf[0..self.path_len :0];
        self.keepalive = try posix.openZ(slave_z, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true }, 0);
        errdefer posix.close(self.keepalive);

        try applyRaw(self.keepalive, initial);
        return self;
    }

    pub fn slavePath(self: *const Pty) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn close(self: *Pty) void {
        posix.close(self.keepalive);
        posix.close(self.master);
    }
};

// ---------------------------------------------------------------------------
// errno-exact non-blocking I/O
// ---------------------------------------------------------------------------

pub const IoResult = union(enum) {
    bytes: usize,
    would_block,
    failed: linux.E,
};

pub fn rawRead(fd: posix.fd_t, buf: []u8) IoResult {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        switch (linux.E.init(rc)) {
            .SUCCESS => return .{ .bytes = rc },
            .INTR => continue,
            .AGAIN => return .would_block,
            else => |e| return .{ .failed = e },
        }
    }
}

pub fn rawWrite(fd: posix.fd_t, data: []const u8) IoResult {
    while (true) {
        const rc = linux.write(fd, data.ptr, data.len);
        switch (linux.E.init(rc)) {
            .SUCCESS => return .{ .bytes = rc },
            .INTR => continue,
            .AGAIN => return .would_block,
            else => |e| return .{ .failed = e },
        }
    }
}

pub const WriteError = error{ WriteTimeout, WriteFailed };

/// Write the whole buffer, waiting for POLLOUT on short writes, bounded by `timeout_ms`.
pub fn writeAll(fd: posix.fd_t, data: []const u8, timeout_ms: i64) WriteError!void {
    var sent: usize = 0;
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (sent < data.len) {
        switch (rawWrite(fd, data[sent..])) {
            .bytes => |n| sent += n,
            .would_block => {
                const remaining = deadline - std.time.milliTimestamp();
                if (remaining <= 0) return error.WriteTimeout;
                var pfd = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                _ = posix.poll(&pfd, @intCast(@min(remaining, 100))) catch return error.WriteFailed;
            },
            .failed => |e| {
                std.log.warn("write(fd={d}) failed: {s}", .{ fd, @tagName(e) });
                return error.WriteFailed;
            },
        }
    }
}
