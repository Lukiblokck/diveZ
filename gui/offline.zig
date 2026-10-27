//! What a page shows while there is no status from the daemon: what is going on, a line of
//! diagnostics to read out when asking for help, and the button that fixes it.
const std = @import("std");
const dvui = @import("dvui");
const texts = @import("texts.zig");
const widgets = @import("widgets.zig");
const Model = @import("model.zig").Model;

pub fn view(model: *Model) !void {
    if (model.isStarting()) {
        try widgets.busy(@src(), texts.starting);
        return;
    }
    try widgets.paragraph(@src(), model.start_error orelse model.problem, .{});
    if (model.start_error == null and model.detail.len > 0) {
        try widgets.paragraph(@src(), model.detail, .{ .font_style = .caption });
    }
    _ = try dvui.spacer(@src(), .{ .w = 0, .h = 10 }, .{});

    const err = model.last_error;
    const nothing_running = err != null and err.? == error.DaemonNotRunning;
    if (model.start_error != null or nothing_running) {
        if (try dvui.button(@src(), "Start diveZ", .{}, .{})) model.startDaemon(false);
    } else if (err != null and isStuck(err.?)) {
        if (try dvui.button(@src(), "Restart diveZ", .{}, .{})) model.startDaemon(true);
    }
}

/// A diveZ that is there but cannot be talked to: stopping it and starting a new one helps.
fn isStuck(err: anyerror) bool {
    return err == error.DaemonUnreachable or err == error.Unauthorized or err == error.BadResponse or
        err == error.ConnectionLost or err == error.Timeout;
}
