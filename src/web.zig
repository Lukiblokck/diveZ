//! Tiny single-threaded HTTP/1.1 server for the settings/status page.
//!
//! Design constraints: ~zero idle cost (one listening fd in the main poll
//! loop, no threads, no per-connection state kept), loopback only, and hardened
//! against a hostile web page trying to drive it from the user's browser:
//!   * binds 127.0.0.1 only,
//!   * every request needs the per-run random token,
//!   * Host header must be loopback:port (DNS-rebinding defense),
//!   * POST needs the token in a custom header (forces a CORS preflight, which
//!     we never answer) and a matching Origin if one is sent,
//!   * strict CSP, no-store, no referrer (the token lives in the URL).

const std = @import("std");
const posix = std.posix;
const term = @import("term.zig");

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    body: []const u8 = "",
};

pub const Handler = *const fn (ctx: *anyopaque, req: Request, scratch: std.mem.Allocator, res: *Response) void;

const io_deadline_ms = 400;

pub const Server = struct {
    fd: posix.socket_t,
    port: u16,
    token: [32]u8,

    pub fn init() !Server {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        var addr = try std.net.Address.parseIp4("127.0.0.1", 0);
        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 8);
        var len: posix.socklen_t = addr.getOsSockLen();
        try posix.getsockname(fd, &addr.any, &len);

        var raw: [16]u8 = undefined;
        std.crypto.random.bytes(&raw);
        return .{ .fd = fd, .port = addr.getPort(), .token = std.fmt.bytesToHex(raw, .lower) };
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.fd);
    }

    pub fn url(self: *const Server, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/?t={s}", .{ self.port, self.token });
    }

    /// Serve at most one pending connection. Bounded by `io_deadline_ms`.
    pub fn serviceOne(self: *Server, ctx: *anyopaque, handler: Handler, backing: std.mem.Allocator) void {
        const cfd = posix.accept(self.fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch return;
        defer posix.close(cfd);
        self.serve(cfd, ctx, handler, backing);
    }

    fn serve(self: *Server, cfd: posix.socket_t, ctx: *anyopaque, handler: Handler, backing: std.mem.Allocator) void {
        var buf: [8192]u8 = undefined;
        var len: usize = 0;
        var header_end: ?usize = null;
        const deadline = std.time.milliTimestamp() + io_deadline_ms;

        while (true) {
            if (header_end == null) {
                if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |i| header_end = i + 4;
            }
            if (header_end) |he| {
                const need = he + contentLength(buf[0..he]);
                if (need > buf.len) return respond(cfd, 413, "text/plain", "too large");
                if (len >= need) break;
            } else if (len == buf.len) {
                return respond(cfd, 431, "text/plain", "headers too large");
            }
            switch (term.rawRead(cfd, buf[len..])) {
                .bytes => |n| {
                    if (n == 0) return;
                    len += n;
                },
                .would_block => {
                    const remaining = deadline - std.time.milliTimestamp();
                    if (remaining <= 0) return;
                    var pfd = [1]posix.pollfd{.{ .fd = cfd, .events = posix.POLL.IN, .revents = 0 }};
                    _ = posix.poll(&pfd, @intCast(remaining)) catch return;
                },
                .failed => return,
            }
        }

        const he = header_end.?;
        const head = buf[0..he];
        const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return;
        var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
        const method = parts.next() orelse return respond(cfd, 400, "text/plain", "bad request");
        const target = parts.next() orelse return respond(cfd, 400, "text/plain", "bad request");

        var path = target;
        var query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, target, '?')) |q| {
            path = target[0..q];
            query = target[q + 1 ..];
        }

        // Host check (DNS rebinding).
        const host = header(head, "host") orelse return respond(cfd, 400, "text/plain", "no host");
        if (!self.hostAllowed(host)) return respond(cfd, 403, "text/plain", "forbidden");

        const is_post = std.mem.eql(u8, method, "POST");
        if (!is_post and !std.mem.eql(u8, method, "GET")) return respond(cfd, 405, "text/plain", "method not allowed");

        // Token: POST must use the header; GET may use header or ?t=.
        const hdr_token = header(head, "x-divez-token");
        const query_token = queryParam(query, "t");
        const supplied = hdr_token orelse (if (is_post) null else query_token);
        if (supplied == null or !constEq(supplied.?, &self.token)) return respond(cfd, 403, "text/plain", "forbidden");

        if (header(head, "origin")) |origin| {
            if (!self.originAllowed(origin)) return respond(cfd, 403, "text/plain", "forbidden");
        }

        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        var res = Response{};
        handler(ctx, .{ .method = method, .path = path, .body = buf[he..len] }, arena.allocator(), &res);
        respond(cfd, res.status, res.content_type, res.body);
    }

    fn hostAllowed(self: *const Server, host: []const u8) bool {
        var b: [40]u8 = undefined;
        const a = std.fmt.bufPrint(&b, "127.0.0.1:{d}", .{self.port}) catch return false;
        if (std.mem.eql(u8, host, a)) return true;
        const l = std.fmt.bufPrint(&b, "localhost:{d}", .{self.port}) catch return false;
        return std.mem.eql(u8, host, l);
    }

    fn originAllowed(self: *const Server, origin: []const u8) bool {
        var b: [48]u8 = undefined;
        const a = std.fmt.bufPrint(&b, "http://127.0.0.1:{d}", .{self.port}) catch return false;
        if (std.mem.eql(u8, origin, a)) return true;
        const l = std.fmt.bufPrint(&b, "http://localhost:{d}", .{self.port}) catch return false;
        return std.mem.eql(u8, origin, l);
    }
};

fn constEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, b) |x, y| acc |= x ^ y;
    return acc == 0;
}

fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(l[0..colon], name)) return std.mem.trim(u8, l[colon + 1 ..], " \t");
    }
    return null;
}

fn contentLength(head: []const u8) usize {
    const v = header(head, "content-length") orelse return 0;
    return std.fmt.parseInt(usize, v, 10) catch 0;
}

fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) return kv[eq + 1 ..];
    }
    return null;
}

fn respond(fd: posix.socket_t, status: u16, ctype: []const u8, body: []const u8) void {
    const reason = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        else => "Error",
    };
    var hb: [768]u8 = undefined;
    const head = std.fmt.bufPrint(&hb,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "X-Content-Type-Options: nosniff\r\n" ++
            "Referrer-Policy: no-referrer\r\n" ++
            "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'\r\n" ++
            "Connection: close\r\n\r\n",
        .{ status, reason, ctype, body.len },
    ) catch return;
    term.writeAll(fd, head, io_deadline_ms) catch return;
    term.writeAll(fd, body, io_deadline_ms) catch {};
}

test "header and query parsing" {
    const head = "GET /x?t=abc HTTP/1.1\r\nHost: 127.0.0.1:1\r\nX-DiveZ-Token: tok\r\nContent-Length: 12\r\n\r\n";
    try std.testing.expectEqualStrings("tok", header(head, "x-divez-token").?);
    try std.testing.expectEqual(@as(usize, 12), contentLength(head));
    try std.testing.expectEqualStrings("abc", queryParam("a=1&t=abc", "t").?);
    try std.testing.expect(queryParam("a=1", "t") == null);
}

test "constant time compare" {
    try std.testing.expect(constEq("abc", "abc"));
    try std.testing.expect(!constEq("abc", "abd"));
    try std.testing.expect(!constEq("abc", "ab"));
}
