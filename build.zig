// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The protocols a window on Fluxion - or any Wayland desktop - speaks:
    // a toplevel, and a title bar drawn by the compositor where it offers.
    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    // Drawn sharp at any scale: told the screen's, and shown at the
    // window's size whatever the size drawn.
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    // Mica: the compositor blurs the wallpaper behind the window.
    scanner.addSystemProtocol("staging/ext-background-effect/ext-background-effect-v1.xml");
    // The screens - their modes, scale and turn - as Display shows and sets
    // them. Not in wayland-protocols: wlroots' own, kept here.
    scanner.addCustomProtocol(b.path("protocol/wlr-output-management-unstable-v1.xml"));
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_output", 4);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("ext_background_effect_manager_v1", 1);
    scanner.generate("zwlr_output_manager_v1", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("xdg_wm_base", 3);
    scanner.generate("zxdg_decoration_manager_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");

    const widgets_dep = b.dependency("fluxion_widgets", .{ .target = target, .optimize = optimize });
    const widgets = widgets_dep.module("fluxion_widgets");
    // Fluxion UI and the font package exactly as the widgets were built
    // with them: two copies would be two `Font` types.
    const ui_dep = widgets_dep.builder.dependency("fluxion_ui", .{ .target = target, .optimize = optimize });
    const ui = ui_dep.module("fluxion_ui");
    const raster = ui_dep.module("fluxion_ui_raster");
    const image = b.dependency("fluxion_image", .{ .target = target, .optimize = optimize }).module("fluxion_image");
    const dbus = b.dependency("fluxion_dbus", .{ .target = target, .optimize = optimize }).module("fluxion_dbus");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "xkbcommon", .module = xkbcommon },
            .{ .name = "fluxion_widgets", .module = widgets },
            .{ .name = "fluxion_widgets_gpu", .module = widgets_dep.module("fluxion_widgets_gpu") },
            .{ .name = "fluxion_ui", .module = ui },
            .{ .name = "fluxion_ui_raster", .module = raster },
            .{ .name = "fluxion_image", .module = image },
            .{ .name = "fluxion_dbus", .module = dbus },
        },
    });
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("xkbcommon", .{});

    const exe = b.addExecutable(.{ .name = "fluxion-settings", .root_module = mod });
    b.installArtifact(exe);
    b.installFile("data/org.fluxion.Settings.desktop", "share/applications/org.fluxion.Settings.desktop");

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Settings").dependOn(&run.step);

    const tests = b.addTest(.{ .name = "fluxion-settings-tests", .root_module = mod });
    b.step("test", "Run the test suite").dependOn(&b.addRunArtifact(tests).step);
}
