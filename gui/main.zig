//! divez-gui: DVUI window for the divez daemon. This file only runs the SDL loop;
//! screens live in ui.zig, daemon state in model.zig and background work in worker.zig.
const std = @import("std");
const dvui = @import("dvui");
const Model = @import("model.zig").Model;
const ui = @import("ui.zig");
const settings = @import("settings.zig");
const worker = @import("worker.zig");

comptime {
    std.debug.assert(dvui.backend_kind == .sdl);
}
const Backend = dvui.backend;

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

const poll_interval_ms = 1000;

/// Called on the worker thread when a result is ready: wake the window from its event wait.
fn wakeUi(ctx: ?*anyopaque) void {
    const win: *dvui.Window = @ptrCast(@alignCast(ctx.?));
    dvui.refresh(win, @src(), null);
}

/// The worker is stuck in a native dialog and cannot be cancelled. Leave the process directly
/// with the exit_group syscall: libc's exit() can block on stdio locks the stuck thread holds.
fn exitWithoutWorker() noreturn {
    std.log.warn("exiting without waiting for the file dialog that is still open", .{});
    std.os.linux.exit_group(0);
}

pub fn main() !void {
    defer if (gpa_instance.deinit() != .ok) @panic("memory leak on exit");

    var runner = worker.Runner{ .gpa = gpa, .exec = worker.execute, .wake = wakeUi };
    defer runner.deinit();

    var model = Model{ .gpa = gpa, .runner = &runner };
    defer model.deinit();
    defer settings.deinit();

    var backend = try Backend.initWindow(.{
        .allocator = gpa,
        .size = .{ .w = 580.0, .h = 640.0 },
        .min_size = .{ .w = 420.0, .h = 320.0 },
        .vsync = false,
        .title = "diveZ",
    });
    defer backend.deinit();

    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{});
    defer win.deinit();

    // The worker wakes the window, so it must stop before the window is destroyed:
    // defers run in reverse order, and this one comes after `win`.
    runner.wake_ctx = &win;
    try runner.start();
    // A file dialog the user left open blocks the worker; do not make the process wait for it.
    defer if (!runner.stopWithin(2000)) exitWithoutWorker();

    while (true) {
        model.update();
        model.pollIfDue(poll_interval_ms);

        const nstime = win.beginWait(backend.hasEvent());
        try win.begin(nstime);

        const quit = try backend.addAllEvents(&win);
        if (quit and ui.mayClose(&model)) break;

        _ = Backend.c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 255);
        _ = Backend.c.SDL_RenderClear(backend.renderer);

        try ui.frame(&model);

        const end_micros = try win.end(.{});
        if (ui.closeConfirmed()) break;
        backend.setCursor(win.cursorRequested());
        backend.textInputRect(win.textInputRequested());
        backend.renderPresent();

        // Wake up when the next poll is due; finished jobs wake the window by themselves.
        // A result that arrived while this iteration was running has had its wake-up consumed by
        // the event loop above, so check for it here instead of sleeping on it.
        const wait_micros: u32 = if (model.hasPendingResults()) 0 else @min(win.waitTime(end_micros, null), model.untilNextPollMicros(poll_interval_ms));
        backend.waitEventTimeout(wait_micros);
    }
}
