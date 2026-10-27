//! divez-gui screens: navigation, pages and the actions they trigger. Actions run on the
//! worker thread; a spinner replaces the buttons until the result comes back.
const std = @import("std");
const dvui = @import("dvui");
const client = @import("client.zig");
const texts = @import("texts.zig");
const notice = @import("notice.zig");
const widgets = @import("widgets.zig");
const settings = @import("settings.zig");
const worker = @import("worker.zig");
const offline = @import("offline.zig");
const Model = @import("model.zig").Model;

const Page = enum { home, captures, settings };

var page: Page = .home;
var quit_confirmed = false;
var close_prompt = false; // the window was asked to close with unsaved changes
var close_dialog_open = false;
var close_confirmed = false;
/// The daemon action in progress, if any. Only one runs at a time.
var action_busy: ?client.Action = null;

/// Ask whether the window may close. True when it may; false after opening a confirmation
/// because the settings form has unsaved changes.
pub fn mayClose(model: *const Model) bool {
    if (close_confirmed or !settings.hasUnsavedChanges(model)) return true;
    if (!close_dialog_open) close_prompt = true;
    return false;
}

/// True once the user agreed to close despite unsaved changes.
pub fn closeConfirmed() bool {
    return close_confirmed;
}

fn onCloseDialog(_: u32, response: dvui.enums.DialogResponse) anyerror!void {
    close_dialog_open = false;
    if (response == .ok) close_confirmed = true;
    dvui.refresh(null, @src(), null); // draw a frame now so the decision takes effect at once
}

pub fn frame(model: *Model) !void {
    widgets.cancelDialogOnEscape();
    widgets.handleZoomKeys();
    if (close_prompt) {
        close_prompt = false;
        close_dialog_open = true;
        try widgets.confirm(@src(), .{
            .title = "Quit diveZ",
            .message = "You have unsaved changes in Settings. They will be lost if you quit now. Quit?",
            .ok_label = "Quit without saving",
            .cancel_label = "Go back",
            .callafterFn = onCloseDialog,
        });
    }

    handleFinished(model);
    if (quit_confirmed) {
        quit_confirmed = false;
        startAction(model, .quit);
    }

    var root = try dvui.box(@src(), .vertical, .{ .expand = .both, .background = true, .color_fill = .{ .name = .fill_window } });
    defer root.deinit();

    try navigation();
    try dvui.separator(@src(), .{ .expand = .horizontal });
    // Above the page, not below: a long page (Ajustes) would push a bottom bar out of the window.
    try noticeBar(model);

    {
        var scroll = try dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();
        var body = try dvui.box(@src(), .vertical, .{ .expand = .horizontal, .padding = dvui.Rect.all(12) });
        defer body.deinit();
        switch (page) {
            .home => try home(model),
            .captures => try captures(model),
            .settings => try settings.page(model),
        }
    }
}

/// Hand every finished background job to the screen that asked for it.
fn handleFinished(model: *Model) void {
    while (model.nextFinished()) |res| {
        switch (res) {
            .action => |a| {
                var outcome = a.outcome;
                defer outcome.deinit();
                finishAction(model, a.action, outcome);
            },
            .save => |done| {
                var outcome = done;
                defer outcome.deinit();
                settings.onSaved(model, outcome);
            },
            .detect => |done| settings.onDetected(done), // takes ownership
            .pick => |p| settings.onPicked(model.gpa, p.field, p.path), // takes ownership of the path
            .status, .start => unreachable, // applied by Model.update
        }
    }
}

fn navigation() !void {
    var bar = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal, .padding = dvui.Rect.all(6) });
    defer bar.deinit();

    if (try dvui.button(@src(), "Home", .{}, tabOptions(page == .home))) selectPage(.home);
    if (try dvui.button(@src(), "Captures", .{}, tabOptions(page == .captures))) selectPage(.captures);
    if (try dvui.button(@src(), "Settings", .{}, tabOptions(page == .settings))) selectPage(.settings);
}

fn tabOptions(active: bool) dvui.Options {
    var o = dvui.Options{};
    if (active) o = o.override(dvui.themeGet().style_accent);
    return o;
}

fn selectPage(p: Page) void {
    if (p != page) notice.clear();
    page = p;
}

fn home(model: *Model) !void {
    try dvui.labelNoFmt(@src(), "diveZ", .{ .font_style = .title });

    const s = if (model.snapshot) |*snap| snap.value else {
        try offline.view(model);
        return;
    };

    try dvui.label(@src(), "diveZ service: v{s}", .{s.version}, .{});
    if (s.serial_online) {
        try dvui.label(@src(), "Diver unit: connected ({s})", .{s.serial_path}, .{});
    } else {
        try dvui.labelNoFmt(@src(), "Diver unit: not connected", .{});
        if (s.serial_error.len > 0) try widgets.paragraph(@src(), texts.serialProblem(s.serial_error), .{ .font_style = .caption });
    }
    try dvui.label(@src(), "Wine: {s}", .{if (s.wine_found) "found" else "not found"}, .{});
    if (!s.wine_found) try widgets.paragraph(@src(), "Install Wine to be able to open Diver-Office.", .{ .font_style = .caption });
    try dvui.label(@src(), "COM port for Diver-Office: {s}", .{if (s.prefix_ready) "ready" else "not published"}, .{});
    try dvui.label(@src(), "Diver-Office: {s}", .{if (s.diver_running) "running" else "stopped"}, .{});
    try dvui.label(@src(), "Data: {d} B to the device, {d} B from the device", .{ s.to_device, s.from_device }, .{});

    _ = try dvui.spacer(@src(), .{ .w = 0, .h = 10 }, .{});

    if (action_busy) |a| {
        try widgets.busy(@src(), busyText(a));
        return;
    }

    {
        var buttons = try dvui.box(@src(), .horizontal, .{});
        defer buttons.deinit();
        try homeButtons(model, s);
    }
    _ = try dvui.spacer(@src(), .{ .w = 0, .h = 14 }, .{});
    try widgets.paragraph(@src(), "Tip: Ctrl and + / − change the text size; Ctrl and 0 resets it.", .{ .font_style = .caption });
}

fn homeButtons(model: *Model, s: client.Status) !void {
    if (!s.diver_running) {
        if (try dvui.button(@src(), "Open Diver-Office", .{}, .{})) startAction(model, .launch);
    }
    if (try dvui.button(@src(), "Quit diveZ", .{}, .{})) {
        try widgets.confirm(@src(), .{
            .title = "Quit diveZ",
            .message = if (s.diver_running)
                "diveZ will close, and so will Diver-Office, which is running. Continue?"
            else
                "diveZ will close. Continue?",
            .ok_label = "Quit",
            .cancel_label = "Cancel",
            .callafterFn = onQuitDialog,
        });
    }
}

fn captures(model: *Model) !void {
    try dvui.labelNoFmt(@src(), "Captures", .{ .font_style = .title });

    const s = if (model.snapshot) |*snap| snap.value else {
        try offline.view(model);
        return;
    };

    try widgets.paragraph(@src(), "Records of the communication with the unit are saved here.", .{});
    try dvui.labelNoFmt(@src(), "Folder:", .{});
    try widgets.paragraph(@src(), s.capture_dir, .{});

    _ = try dvui.spacer(@src(), .{ .w = 0, .h = 10 }, .{});
    if (action_busy) |a| {
        try widgets.busy(@src(), busyText(a));
    } else if (try dvui.button(@src(), "Open captures folder", .{}, .{})) {
        startAction(model, .open_captures);
    }
}

fn noticeBar(model: *const Model) !void {
    if (notice.current) |n| {
        const err_style = dvui.themeGet().style_err;
        var row_opts = dvui.Options{ .expand = .horizontal, .padding = dvui.Rect.all(8), .background = n.is_error };
        var text_opts = dvui.Options{ .gravity_y = 0.5 };
        if (n.is_error) {
            // The error style sets fill and text colors; the fill only shows with a background.
            row_opts = row_opts.override(err_style);
            row_opts.background = true;
            text_opts.color_text = err_style.color_text;
        }
        // Vertical on purpose: a paragraph inside a horizontal box asks for its full one-line
        // width and would push the button out of the window.
        var row = try dvui.box(@src(), .vertical, row_opts);
        defer row.deinit();
        try widgets.paragraph(@src(), n.text, text_opts);
        if (try dvui.button(@src(), "Close", .{}, .{ .gravity_x = 1.0 })) notice.clear();
    } else if (model.unresponsive()) {
        try widgets.busy(@src(), "diveZ is slow to answer…");
    }
}

/// Called by DVUI when the confirmation dialog closes; the action starts on the next frame.
fn onQuitDialog(_: u32, response: dvui.enums.DialogResponse) anyerror!void {
    if (response == .ok) quit_confirmed = true;
    dvui.refresh(null, @src(), null);
}

fn busyText(action: client.Action) []const u8 {
    return switch (action) {
        .launch => "Opening Diver-Office…",
        .open_captures => "Opening the captures folder…",
        .quit => "Closing diveZ…",
    };
}

fn successText(action: client.Action) []const u8 {
    return switch (action) {
        .launch => "Diver-Office is starting.",
        .open_captures => "Opening the captures folder…",
        .quit => "diveZ has closed.",
    };
}

fn startAction(model: *Model, action: client.Action) void {
    if (action_busy != null) return;
    if (model.submit(.{ .action = action })) {
        action_busy = action;
    } else {
        notice.failure(texts.requestFailure(error.OutOfMemory));
    }
}

fn finishAction(model: *Model, action: client.Action, outcome: worker.Done(client.Outcome)) void {
    action_busy = null;
    model.refreshNow();
    switch (outcome) {
        // After a quit the daemon drops the connection, which is the expected outcome.
        .err => |err| if (action == .quit and (err == error.DaemonNotRunning or err == error.ConnectionLost))
            notice.info(successText(action))
        else if (err == error.Timeout)
            notice.failure(texts.change_timed_out)
        else
            notice.failure(texts.requestFailure(err)),
        .ok => |o| if (o.value.ok)
            notice.info(successText(action))
        else
            // Strings from `texts` are static, so the notice never points into `outcome`.
            notice.failure(texts.launchFailure(o.value.reason)),
    }
}
