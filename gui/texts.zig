//! User-facing messages (English). Pure functions so they can be unit tested.
const std = @import("std");

/// Message for an error returned by the daemon's /api/launch (`LaunchError` names).
pub fn launchFailure(reason: []const u8) []const u8 {
    const map = .{
        .{ "AlreadyRunning", "Diver-Office is already running." },
        .{ "WineNotFound", "Wine was not found. Install it to be able to open Diver-Office." },
        .{ "ExeNotFound", "Diver-Office was not found in the Wine prefix." },
        .{ "SpawnFailed", "Diver-Office could not be started." },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, reason, entry[0])) return entry[1];
    }
    return "The action could not be completed.";
}

pub const connecting = "Connecting to diveZ…";
pub const starting = "Starting diveZ…";

/// Message for a failed request to the daemon (client.Error plus OutOfMemory).
pub fn requestFailure(err: anyerror) []const u8 {
    return switch (err) {
        error.DaemonNotRunning => "diveZ is not running.",
        error.DaemonUnreachable => "diveZ seems to be running, but this window cannot reach it.",
        error.Timeout => "diveZ is not answering.",
        error.ConnectionLost => "The connection to diveZ was interrupted.",
        error.Unauthorized => "diveZ rejected this window’s access key.",
        error.OutOfMemory => "Out of memory.",
        else => "diveZ sent an answer this window does not understand.",
    };
}

/// Why diveZ could not be started from this window (see client.startDaemon / stopDaemon).
pub fn startFailure(err: anyerror) []const u8 {
    return switch (err) {
        error.ProgramNotFound => "diveZ could not be started: the “divez” program was not found next to divez-gui, in ~/.local/bin or in your PATH.",
        error.StopFailed => "The diveZ that is running would not quit. Close it from your system’s task manager (look for “divez”) and try again.",
        else => "diveZ could not be started. The file ~/diveZ/divez.log may say why.",
    };
}

/// A change request that got no answer in time: the daemon may still apply it.
pub const change_timed_out = "diveZ did not answer in time. The change may still be applied once it does: check the status in a few seconds.";

pub const detect_failed = "The list of units could not be read. Press “Find units” to try again.";

/// Explanation for the daemon's `serial_error` code (see tryOpenSerial in src/main.zig).
pub fn serialProblem(code: []const u8) []const u8 {
    const map = .{
        .{ "missing", "No unit was detected. Plug the Diver reader into a USB port and check the cable." },
        .{ "permission", "Not allowed to use the unit. Your user must be in the serial-port group (the installer sets this up); then log out and back in." },
        .{ "DeviceBusy", "Another program is using the unit. Close it and try again." },
        .{ "not_serial", "That device does not behave like a serial port. Make sure it is the Diver reader." },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, code, entry[0])) return entry[1];
    }
    return "The unit could not be opened.";
}

test "messages" {
    try std.testing.expectEqualStrings("Diver-Office is already running.", launchFailure("AlreadyRunning"));
    try std.testing.expectEqualStrings("The action could not be completed.", launchFailure("whatever"));
    try std.testing.expect(requestFailure(error.Timeout).len > 0);
    try std.testing.expect(requestFailure(error.BadResponse).len > 0);
}

test "every kind of connection problem reads differently" {
    const errs = [_]anyerror{ error.DaemonNotRunning, error.DaemonUnreachable, error.Timeout, error.ConnectionLost, error.Unauthorized, error.BadResponse };
    for (errs, 0..) |a, i| {
        for (errs[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, requestFailure(a), requestFailure(b)));
    }
    try std.testing.expect(!std.mem.eql(u8, startFailure(error.ProgramNotFound), startFailure(error.StartFailed)));
    try std.testing.expect(!std.mem.eql(u8, startFailure(error.StopFailed), startFailure(error.StartFailed)));
}

test "every known serial error code has its own explanation" {
    const generic = serialProblem("anything else");
    for ([_][]const u8{ "missing", "permission", "DeviceBusy", "not_serial" }) |code| {
        try std.testing.expect(!std.mem.eql(u8, serialProblem(code), generic));
    }
}
