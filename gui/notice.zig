//! The one-line message bar at the bottom of the window. Texts must be static
//! (string literals): the bar keeps pointing at them until the next message.
pub const Notice = struct { text: []const u8, is_error: bool };

pub var current: ?Notice = null;

pub fn info(text: []const u8) void {
    current = .{ .text = text, .is_error = false };
}

pub fn failure(text: []const u8) void {
    current = .{ .text = text, .is_error = true };
}

pub fn clear() void {
    current = null;
}
