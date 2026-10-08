// SPDX-License-Identifier: BSD-2-Clause

//! Personalization: the wallpaper, and the colors - light or dark, and the
//! accent everything chosen is lit with.

const std = @import("std");

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");
const Pictures = @import("../Pictures.zig");
const Store = @import("../Store.zig");

pub const State = struct {
    mode_choice: Kit.Dropdown = .{},
    search_choice: Kit.Dropdown = .{},
    alignment_choice: Kit.Dropdown = .{},
};

const search_names = [_][]const u8{ "Hide", "Search icon only" };
const alignment_names = [_][]const u8{ "Center", "Left" };

/// Accents to choose from: the default and a few of the colours Windows
/// offers, which are colours, not anybody's brand.
const accents = [_]u32{
    0xFF1F6FCC, 0xFF0063B1, 0xFF0099BC, 0xFF00B294, 0xFF0E8A7D, 0xFF107C10,
    0xFF7A4FD6, 0xFF8764B8, 0xFFB146C2, 0xFFC23B6F, 0xFFE81123, 0xFFD06A12,
    0xFFCA5010, 0xFFC19C00, 0xFF5D6B78, 0xFF4C4A48,
};

pub fn draw(app: *Settings, kit: *Kit) void {
    switch (app.sub) {
        .background => background(app, kit),
        .colors => colors(app, kit),
        .taskbar => taskbar(app, kit),
        .desktop_icons => desktopIcons(app, kit),
        else => {
            app.linkCard(kit, .background, .image, "Background image");
            app.linkCard(kit, .colors, .color, "Light or dark, the accent color");
            app.linkCard(kit, .taskbar, .tab_desktop, "Taskbar items, alignment, badges");
            app.linkCard(kit, .desktop_icons, .desktop, "Recycle Bin, This PC, and the other icons on the desktop");
        },
    }
}

/// What is on the taskbar and how it behaves - as Windows 11's page has
/// it, as far as the taskbar here does it.
fn taskbar(app: *Settings, kit: *Kit) void {
    const s = &app.personalization_state;
    const t = &app.store.taskbar;
    kit.section("Taskbar items");
    kit.cardBegin("tb/search", .{ .icon = .search, .title = "Search", .description = "The search button beside start" });
    if (!s.search_choice.open) s.search_choice.selected = @intFromEnum(t.search);
    if (kit.dropdown("tb/search/list", &s.search_choice, &search_names, .fixed(200))) {
        t.search = @enumFromInt(s.search_choice.selected);
        app.save();
    }
    _ = kit.cardEnd(false);
    toggleCard(app, kit, "tb/taskview", .square_multiple, "Task view", "Your windows and desktops, at a glance", &t.task_view);

    kit.section("Taskbar behaviors");
    kit.cardBegin("tb/alignment", .{ .icon = .tab_desktop, .title = "Taskbar alignment", .description = "Where start and the apps sit" });
    if (!s.alignment_choice.open) s.alignment_choice.selected = @intFromEnum(t.alignment);
    if (kit.dropdown("tb/alignment/list", &s.alignment_choice, &alignment_names, .fixed(160))) {
        t.alignment = @enumFromInt(s.alignment_choice.selected);
        app.save();
    }
    _ = kit.cardEnd(false);
    toggleCard(app, kit, "tb/badges", .alert_badge, "Show badges on taskbar apps", "Counts of what is new, on an app's button", &t.badges);
    toggleCard(app, kit, "tb/flashing", .alert, "Show flashing on taskbar apps", "An app's button lit when it wants your attention", &t.flashing);
    toggleCard(app, kit, "tb/corner", .desktop, "Select the far corner of the taskbar to show the desktop", "", &t.show_desktop_corner);
}

/// Which of the system's icons are on the desktop - Windows' Desktop Icon
/// Settings. The size and the arranging are the desktop's own menu's.
fn desktopIcons(app: *Settings, kit: *Kit) void {
    const d = &app.store.desktop_icons;
    kit.section("Desktop icons");
    toggleCard(app, kit, "di/recycle", .delete, "Recycle Bin", "What was deleted, until it is emptied", &d.recycle_bin);
    toggleCard(app, kit, "di/computer", .desktop, "This PC", "The whole of this computer's files", &d.computer);
    toggleCard(app, kit, "di/home", .folder, "User's files", "Your home folder", &d.home);
    toggleCard(app, kit, "di/network", .globe, "Network", "Other computers on the network", &d.network);
    kit.label("Right-click the desktop for the icons' size, and how they are arranged and sorted.", .caption, kit.theme.palette.text_secondary);
}

fn toggleCard(app: *Settings, kit: *Kit, id: []const u8, icon: widgets.icons.Name, title: []const u8, description: []const u8, value: *bool) void {
    kit.cardBegin(id, .{ .icon = icon, .title = title, .description = description });
    if (kit.toggle(kit.print("{s}/toggle", .{id}), value, .{})) app.save();
    _ = kit.cardEnd(false);
}

fn background(app: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    kit.section("Choose a photo");
    const list = app.pictures.list;
    if (list.len == 0) {
        kit.label("No pictures found under /usr/share/backgrounds or Pictures/Wallpapers.", .body, p.text_secondary);
        return;
    }
    const current = app.store.wallpaper() orelse "";
    u.open(.{ .width = .grow, .wrap = true, .gap = 8, .wrap_gap = 8 });
    defer u.close();
    for (list, 0..) |*picture, i| {
        if (picture.failed) continue;
        const id = kit.print("wallpaper/{d}", .{i});
        const chosen = std.mem.eql(u8, picture.path, current);
        const hovered = u.isPointerOver(id);
        u.open(.{
            .id = id,
            .width = .fixed(Pictures.thumb_w),
            .height = .fixed(Pictures.thumb_h),
            .corner_radius = .all(6),
            .background_color = p.subtle_secondary,
            .border = if (chosen) .{ .color = p.accent, .width = .all(3) } else if (hovered) .{ .color = p.text_tertiary, .width = .all(1) } else null,
            .image = if (picture.texture) |t| .{ .texture = t } else null,
        });
        if (u.justReleased()) {
            app.store.setWallpaper(picture.path);
            app.save();
        }
        u.close();
    }
}

fn colors(app: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const s = &app.personalization_state;
    s.mode_choice.selected = if (app.store.mode == .light) 0 else 1;
    kit.cardBegin("mode", .{ .icon = .dark_theme, .title = "Choose your mode", .description = "Change the colors that appear in Fluxion and your apps" });
    if (kit.dropdown("mode/list", &s.mode_choice, &.{ "Light", "Dark" }, .fixed(160))) {
        app.store.mode = if (s.mode_choice.selected == 0) .light else .dark;
        app.save();
        app.retheme();
    }
    _ = kit.cardEnd(false);

    kit.cardBegin("accent", .{ .icon = .color, .title = "Accent color", .description = "Used for buttons, switches and selections" });
    _ = kit.cardEnd(false);
    u.open(.{ .width = .grow, .wrap = true, .gap = 8, .wrap_gap = 8, .padding = .trbl(8, 16, 16, 16) });
    defer u.close();
    for (accents, 0..) |colour, i| {
        const id = kit.print("accent/{d}", .{i});
        const chosen = colour == app.store.accent;
        const hovered = u.isPointerOver(id);
        u.open(.{
            .id = id,
            .width = .fixed(40),
            .height = .fixed(40),
            .corner_radius = .all(6),
            .background_color = widgets.argb(colour),
            .border = if (chosen) .{ .color = p.text_primary, .width = .all(3) } else if (hovered) .{ .color = p.text_secondary, .width = .all(1) } else null,
            .align_x = .center,
            .align_y = .center,
        });
        if (chosen) kit.icon(.checkmark, 16, widgets.argb(0xFFFFFFFF), .filled);
        if (u.justReleased()) {
            app.store.accent = colour;
            app.save();
            app.retheme();
        }
        u.close();
    }
}
