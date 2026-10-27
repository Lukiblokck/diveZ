//! Settings page: a form over the daemon's persisted settings. The form state and
//! all validation rules live in form.zig; this file only draws it and talks to the daemon.
const std = @import("std");
const dvui = @import("dvui");
const client = @import("client.zig");
const texts = @import("texts.zig");
const notice = @import("notice.zig");
const widgets = @import("widgets.zig");
const form_mod = @import("form.zig");
const worker = @import("worker.zig");
const offline = @import("offline.zig");
const Model = @import("model.zig").Model;

const Field = form_mod.Field;
const PickKind = worker.PickKind;

// Page state. It survives switching pages so half-edited values are not lost.
var form = form_mod.Form{};
var loaded = false;
var detected: ?client.DetectSnapshot = null;
var save_confirmed = false;
// Background jobs in progress; each shows a spinner and blocks a second submission.
var saving = false;
var detecting = false;
var picking: ?Field = null;

const warning_text = dvui.Options{ .color_text = .{ .color = .{ .r = 0x8a, .g = 0x5a, .b = 0x00 } } };
const error_text = dvui.Options{ .color_text = .{ .color = .{ .r = 0xc0, .g = 0x1c, .b = 0x1c } } };

/// True when the form holds edits the daemon does not have yet.
pub fn hasUnsavedChanges(model: *const Model) bool {
    if (!loaded) return false;
    const snap = model.snapshot orelse return false;
    return form.changesFrom(snap.value.settings).any();
}

pub fn deinit() void {
    if (detected) |*d| d.deinit();
    detected = null;
}

pub fn page(model: *Model) !void {
    if (save_confirmed) {
        save_confirmed = false;
        startSave(model);
    }

    try dvui.labelNoFmt(@src(), "Settings", .{ .font_style = .title });

    const current = if (model.snapshot) |*snap| snap.value.settings else {
        try offline.view(model);
        return;
    };
    if (!loaded) {
        form.load(current);
        loaded = true;
        refreshDetect(model);
    }

    try serialRow(model);
    try pathRow(model, .prefix, "Wine prefix", "Empty = use $WINEPREFIX if it is set, otherwise ~/.wine.", .folder);
    try pathRow(model, .exe, "Diver-Office program", "Empty = look for Diver-Office automatically in the prefix’s “Program Files”.", .file);
    try pathRow(model, .capture_dir, "Captures folder", "Empty = ~/diveZ/captures. A change takes effect the next time diveZ starts.", .folder);
    {
        var row = try dvui.box(@src(), .vertical, .{ .expand = .horizontal, .padding = .{ .y = 6, .h = 6 } });
        defer row.deinit();
        _ = try dvui.checkbox(@src(), &form.autolaunch, "Open Diver-Office automatically when diveZ starts", .{});
    }
    try buttons(model, current);
}

fn serialRow(model: *Model) !void {
    var row = try dvui.box(@src(), .vertical, .{ .expand = .horizontal, .padding = .{ .y = 6, .h = 6 } });
    defer row.deinit();
    try dvui.labelNoFmt(@src(), "Diver unit (USB port)", .{ .font_style = .heading });
    try widgets.paragraph(@src(), "“Automatic” uses /dev/diver0 if it exists, otherwise the first USB unit found.", .{ .font_style = .caption });

    {
        var h = try dvui.box(@src(), .horizontal, .{});
        defer h.deinit();

        // Entry 0 is "auto"; then the detected units; then the saved one if it is not detected.
        var display: [18][]const u8 = undefined;
        display[0] = "Automatic";
        var n: usize = 1;
        if (detected) |*d| {
            for (d.value.serials) |s| {
                if (n >= display.len - 1) break;
                display[n] = s;
                n += 1;
            }
        }
        const cur = form.get(.serial);
        var choice: usize = 0;
        if (!std.mem.eql(u8, cur, "auto")) {
            choice = n;
            for (display[1..n], 1..) |e, i| {
                if (std.mem.eql(u8, e, cur)) {
                    choice = i;
                    break;
                }
            }
            if (choice == n) {
                display[n] = cur;
                n += 1;
            }
        }
        if (try dvui.dropdown(@src(), display[0..n], &choice, .{ .min_size_content = .{ .w = 220, .h = 0 } })) {
            if (choice == 0) {
                _ = form.set(.serial, "auto");
            } else if (!std.mem.eql(u8, display[choice], cur)) { // never copy a buffer onto itself
                _ = form.set(.serial, display[choice]);
            }
            form.setError(.serial, null);
            form.checkPaths();
        }
        if (detecting) {
            try widgets.busy(@src(), "Searching…");
        } else if (try dvui.button(@src(), "Find units", .{}, .{ .gravity_y = 0.5 })) {
            refreshDetect(model);
        }
    }
    try fieldError(@src(), .serial);
}

fn pathRow(model: *Model, comptime f: Field, title: []const u8, help: []const u8, kind: PickKind) !void {
    var row = try dvui.box(@src(), .vertical, .{ .id_extra = @intFromEnum(f), .expand = .horizontal, .padding = .{ .y = 6, .h = 6 } });
    defer row.deinit();
    try dvui.labelNoFmt(@src(), title, .{ .font_style = .heading });
    try widgets.paragraph(@src(), help, .{ .font_style = .caption });
    {
        var h = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal });
        defer h.deinit();
        var te = try dvui.textEntry(@src(), .{ .text = .{ .buffer = &@field(form, @tagName(f)) } }, .{ .expand = .horizontal });
        const edited = te.text_changed;
        te.deinit();
        if (edited) {
            form.setError(f, null);
            form.checkPaths();
        }
        if (picking) |active| {
            if (active == f) {
                try widgets.busy(@src(), "Waiting for your choice…");
            } else {
                // Only one dialog at a time: the other buttons are shown but inert.
                try dvui.labelNoFmt(@src(), "Choose…", .{ .gravity_y = 0.5, .padding = dvui.Rect.all(6), .color_text = .{ .color = .{ .r = 0x9a, .g = 0x9a, .b = 0x9a } } });
            }
        } else if (try dvui.button(@src(), "Choose…", .{}, .{ .gravity_y = 0.5 })) {
            startPick(model, f, kind, title);
        }
    }
    try fieldError(@src(), f);
}

fn fieldError(src: std.builtin.SourceLocation, f: Field) !void {
    if (form.errorOf(f)) |msg| {
        try widgets.paragraph(src, msg, error_text);
    } else if (form.warningOf(f)) |msg| {
        try widgets.paragraph(src, msg, warning_text);
    }
}

/// Open the native file/folder dialog on the worker thread (it blocks until the user closes
/// it). Needs zenity, kdialog or similar; without one nothing is returned and the path can
/// still be typed.
fn startPick(model: *Model, comptime f: Field, kind: PickKind, title: []const u8) void {
    if (picking != null) return;
    var start_buf: [form_mod.max_text + 16]u8 = undefined;
    const base = switch (kind) {
        .folder => form.get(f),
        .file => form.get(.prefix),
    };
    const start: ?[]const u8 = if (base.len > 0 and base[0] == '/')
        std.fmt.bufPrint(&start_buf, "{s}{s}", .{ base, if (kind == .file) "/drive_c/" else "/" }) catch null
    else
        null;

    // The job outlives this frame, so it gets its own copies of the strings.
    const owned_title = model.gpa.dupe(u8, title) catch return notice.failure(texts.requestFailure(error.OutOfMemory));
    const owned_start: ?[]const u8 = if (start) |st| model.gpa.dupe(u8, st) catch {
        model.gpa.free(owned_title);
        return notice.failure(texts.requestFailure(error.OutOfMemory));
    } else null;

    if (model.submit(.{ .pick = .{ .kind = kind, .field = f, .title = owned_title, .start = owned_start } })) {
        picking = f;
    } else {
        notice.failure(texts.requestFailure(error.OutOfMemory)); // submit already freed the job
    }
}

/// A native dialog finished. Takes ownership of `path`; null means cancelled or unavailable.
pub fn onPicked(gpa: std.mem.Allocator, field: Field, path: ?[]const u8) void {
    picking = null;
    const chosen = path orelse return;
    defer gpa.free(chosen);
    if (form.setField(field, chosen)) form.setError(field, null) else form.setError(field, "The chosen path is too long.");
    form.checkPaths();
}

fn buttons(model: *Model, current: client.Settings) !void {
    const changes = form.changesFrom(current);
    var bar = try dvui.box(@src(), .horizontal, .{ .padding = .{ .y = 10 } });
    defer bar.deinit();

    if (saving) {
        try widgets.busy(@src(), "Saving…");
        return;
    }
    if (changes.any()) {
        if (try dvui.button(@src(), "Save", .{}, .{})) try requestSave(model, changes);
        if (try dvui.button(@src(), "Discard changes", .{}, .{})) {
            form.load(current);
            notice.clear();
        }
    }
    if (try dvui.button(@src(), "Defaults", .{}, .{})) {
        form.loadDefaults();
        notice.info("Defaults loaded.");
    }
    if (changes.any()) try widgets.paragraph(@src(), "You have unsaved changes.", .{ .font_style = .caption });
}

fn requestSave(model: *Model, changes: form_mod.Form.Changes) !void {
    if (!form.validate()) {
        notice.failure("Check the fields marked in red.");
        return;
    }
    if (changes.touchesConnection()) {
        try widgets.confirm(@src(), .{
            .title = "Save settings",
            .message = "Changing the unit or the Wine prefix restarts the connection to the unit and may interrupt a transfer in progress. Save?",
            .ok_label = "Save",
            .cancel_label = "Cancel",
            .callafterFn = onSaveDialog,
        });
        return;
    }
    startSave(model);
}

fn onSaveDialog(_: u32, response: dvui.enums.DialogResponse) anyerror!void {
    if (response == .ok) save_confirmed = true;
    dvui.refresh(null, @src(), null); // draw a frame now so the decision takes effect at once
}

/// Send the form to the daemon on the worker thread.
fn startSave(model: *Model) void {
    if (saving) return;
    const body = client.configBody(model.gpa, form.toSettings()) catch return notice.failure(texts.requestFailure(error.OutOfMemory));
    if (model.submit(.{ .save = body })) { // the job owns `body`, and submit frees it on failure
        saving = true;
    } else {
        notice.failure(texts.requestFailure(error.OutOfMemory));
    }
}

/// The daemon answered a save. The caller frees `done`.
pub fn onSaved(model: *Model, done: worker.Done(client.ConfigOutcome)) void {
    saving = false;
    model.refreshNow();
    switch (done) {
        .err => |err| notice.failure(if (err == error.Timeout) texts.change_timed_out else texts.requestFailure(err)),
        .ok => |outcome| {
            const r = outcome.value;
            if (!r.ok) {
                _ = form.applyServerReason(r.reason);
                notice.failure("diveZ did not accept the settings. Check the fields marked in red.");
            } else if (!r.saved) {
                notice.failure("The settings were applied but could not be saved to disk: they will be lost when diveZ restarts.");
            } else if (r.restart_required) {
                notice.info("Settings saved. The captures folder will change the next time diveZ starts.");
            } else {
                notice.info("Settings saved.");
            }
        },
    }
}

fn refreshDetect(model: *Model) void {
    if (detecting) return;
    if (model.submit(.detect)) detecting = true;
}

/// The detection finished. Takes ownership of the result; the old list stays on failure.
pub fn onDetected(done: worker.Done(client.DetectSnapshot)) void {
    detecting = false;
    switch (done) {
        .ok => |snap| {
            if (detected) |*d| d.deinit();
            detected = snap;
        },
        .err => |err| notice.failure(if (err == error.DaemonNotRunning) texts.requestFailure(err) else texts.detect_failed),
    }
}
