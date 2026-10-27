const std = @import("std");

pub fn build(b: *std.Build) void {
    // Generic CPU by default: a native build uses the build machine's extensions (AVX...) and
    // dies with "Illegal instruction" on an older machine or a VM that hides them. Nothing here
    // is CPU bound. `-Dcpu=native` opts back in.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    // Default ReleaseSafe: keeps bounds/overflow checks on a long-running daemon.
    // (standardOptimizeOption with a preferred mode would replace -Doptimize by -Drelease.)
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "ReleaseSafe (default), ReleaseSmall, ReleaseFast, Debug") orelse .ReleaseSafe;

    const strip = b.option(bool, "strip", "Strip debug info (smaller binary)") orelse false;

    const exe = b.addExecutable(.{
        .name = "divez",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // termios / pty helpers come from libc
        .strip = strip,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the bridge").dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const config_mod = b.createModule(.{ .root_source_file = b.path("src/config.zig") });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // GUI logic that does not need DVUI is tested on its own (no network needed).
    for ([_][]const u8{ "gui/client.zig", "gui/texts.zig", "gui/form.zig", "gui/jobs.zig", "gui/zoom.zig" }) |path| {
        const t = b.addTest(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
        t.root_module.addImport("config", config_mod);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // divez-gui: DVUI window that talks to the daemon over its HTTP API. Opt-in so the
    // daemon build stays dependency-free and offline (DVUI is a lazy dependency).
    const want_gui = b.option(bool, "gui", "Also build divez-gui (fetches DVUI, builds SDL2 from source)") orelse false;
    if (want_gui) {
        if (b.lazyDependency("dvui", .{ .target = target, .optimize = optimize })) |dvui_dep| {
            const gui = b.addExecutable(.{
                .name = "divez-gui",
                .root_source_file = b.path("gui/main.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
            });
            gui.root_module.addImport("dvui", dvui_dep.module("dvui_sdl"));
            gui.root_module.addImport("config", config_mod);
            b.installArtifact(gui);
        }
    }
}
