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
};

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
        else => {
            app.linkCard(kit, .background, .image, "Background image");
            app.linkCard(kit, .colors, .color, "Light or dark, the accent color");
        },
    }
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
