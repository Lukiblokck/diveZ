//! Small DVUI helpers shared by the screens.
const std = @import("std");
const dvui = @import("dvui");
const zoom = @import("zoom.zig");

/// Text that wraps to the window width (labels do not wrap).
pub fn paragraph(src: std.builtin.SourceLocation, text: []const u8, opts: dvui.Options) !void {
    var tl = try dvui.textLayout(src, .{}, (dvui.Options{ .expand = .horizontal, .background = false }).override(opts));
    defer tl.deinit();
    try tl.addText(text, .{});
}

/// A spinner with a short text: shown while a background job is running.
pub fn busy(src: std.builtin.SourceLocation, text: []const u8) !void {
    var row = try dvui.box(src, .horizontal, .{});
    defer row.deinit();
    try dvui.spinner(@src(), .{ .min_size_content = .{ .w = 20, .h = 20 }, .gravity_y = 0.5 });
    try dvui.labelNoFmt(@src(), text, .{ .gravity_y = 0.5, .padding = .{ .x = 6 } });
}

const OpenDialog = struct { id: u32, on_close: ?dvui.DialogCallAfterFn };
var open_dialog: ?OpenDialog = null;

/// Show a modal dialog that Escape also cancels (DVUI's own dialogs only react to their buttons).
pub fn confirm(src: std.builtin.SourceLocation, opts: dvui.DialogOptions) !void {
    open_dialog = .{ .id = dvui.parentGet().extendId(src, opts.id_extra), .on_close = opts.callafterFn };
    try dvui.dialog(src, opts);
}

/// Call once per frame before drawing: Escape cancels the dialog opened with `confirm`, if any.
pub fn cancelDialogOnEscape() void {
    const d = open_dialog orelse return;
    var still_open = false;
    for (dvui.currentWindow().dialogs.items) |item| {
        if (item.id == d.id) still_open = true;
    }
    if (!still_open) {
        open_dialog = null; // closed with one of its buttons
        return;
    }
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .key) continue;
        const k = e.evt.key;
        if (k.code == .escape and k.action == .down) {
            e.handled = true;
            dvui.dialogRemove(d.id);
            open_dialog = null;
            if (d.on_close) |cb| cb(d.id, .cancel) catch {};
            return;
        }
    }
}

var zoom_base: ?f32 = null; // the window's own scale when the first zoom key arrived
var zoom_level: f32 = 1.0;

/// Call once per frame: Ctrl and +/-/0 enlarge, shrink or reset the text (all widgets scale).
pub fn handleZoomKeys() void {
    const win = dvui.currentWindow();
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .key) continue;
        const k = e.evt.key;
        if (k.action == .up) continue;
        if (!k.mod.has(.lcontrol) and !k.mod.has(.rcontrol)) continue;
        switch (k.code) {
            .equal, .kp_add => zoom_level = zoom.larger(zoom_level),
            .minus, .kp_subtract => zoom_level = zoom.smaller(zoom_level),
            .zero, .kp_0 => zoom_level = 1.0,
            else => continue,
        }
        e.handled = true;
        if (zoom_base == null) zoom_base = win.content_scale;
        win.content_scale = zoom_base.? * zoom_level; // applied when the next frame begins
        dvui.refresh(null, @src(), null);
    }
}
