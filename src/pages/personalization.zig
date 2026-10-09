// SPDX-License-Identifier: BSD-2-Clause

//! Personalization: the wallpaper, the colors - light or dark, and the
//! accent everything chosen is lit with - and the look: Windows 11's or
//! 10's, round or square, floating or docked.

const std = @import("std");

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");
const Pictures = @import("../Pictures.zig");
const Store = @import("../Store.zig");

pub const State = struct {
    background_choice: Kit.Dropdown = .{},
    title_material_choice: Kit.Dropdown = .{},
    window_material_choice: Kit.Dropdown = .{},
    interval_choice: Kit.Dropdown = .{},
    mode_choice: Kit.Dropdown = .{},
    search_choice: Kit.Dropdown = .{},
    alignment_choice: Kit.Dropdown = .{},
    position_choice: Kit.Dropdown = .{},
    combine_choice: Kit.Dropdown = .{},
};

const search_names = [_][]const u8{ "Hide", "Search icon only" };
const alignment_names = [_][]const u8{ "Center", "Left" };
const position_names = [_][]const u8{ "Bottom", "Top", "Left", "Right" };

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
        .themes => themes(app, kit),
        .taskbar => taskbar(app, kit),
        .desktop_icons => desktopIcons(app, kit),
        else => {
            app.linkCard(kit, .background, .image, "Background image");
            app.linkCard(kit, .colors, .color, "Light or dark, the accent color");
            app.linkCard(kit, .themes, .paint_brush, "Windows 11 or Windows 10, rounded or square corners, floating panels");
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
    if (t.search != .hide) toggleCard(app, kit, "tb/search-hover", .search, "Show recent searches when I hover over the search icon", "Windows 11's look", &t.search_hover);
    toggleCard(app, kit, "tb/taskview", .square_multiple, "Task view", "Your windows and desktops, at a glance", &t.task_view);

    kit.section("Taskbar behaviors");
    kit.cardBegin("tb/position", .{ .icon = .tab_desktop, .title = "Taskbar position", .description = "The edge of the screen it is along" });
    if (!s.position_choice.open) s.position_choice.selected = @intFromEnum(t.position);
    if (kit.dropdown("tb/position/list", &s.position_choice, &position_names, .fixed(160))) {
        t.position = @enumFromInt(s.position_choice.selected);
        app.save();
    }
    _ = kit.cardEnd(false);
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
    toggleCard(app, kit, "tb/seconds", .clock, "Show seconds in system tray clock", "Uses more power", &t.seconds);
    toggleCard(app, kit, "tb/peek", .eye, "Use Peek to preview the desktop", "When the pointer rests on the far corner of the taskbar", &t.peek);
    kit.cardBegin("tb/combine", .{ .icon = .tab_desktop, .title = "Combine taskbar buttons and hide labels", .description = "An app's windows under one button, or each its own with its title" });
    if (!s.combine_choice.open) s.combine_choice.selected = @intFromEnum(t.combine);
    if (kit.dropdown("tb/combine/list", &s.combine_choice, &.{ "Always", "When taskbar is full", "Never" }, .fixed(200))) {
        t.combine = @enumFromInt(s.combine_choice.selected);
        app.save();
    }
    _ = kit.cardEnd(false);
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

// -------------------------------------------------------------------------
// Themes
// -------------------------------------------------------------------------

/// The look of everything: Windows 11's or Windows 10's, each shown as it
/// looks, and what can be changed within it. The whole desktop - the
/// shell, the compositor's frames, this window - changes over at once.
fn themes(app: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const look = &app.store.look;
    kit.section("Style");
    {
        u.open(.{ .width = .grow, .gap = 16 });
        defer u.close();
        styleCard(app, kit, .win11, "Windows 11", "Rounded corners, centred taskbar, floating start menu");
        styleCard(app, kit, .win10, "Windows 10", "Square corners, docked start menu with live tiles, Action Center");
    }

    // Windows 10 is square and docked: what it has no say in is greyed, and
    // says why.
    const ten = look.style == .win10;
    kit.section("Corners and surfaces");
    lookCard(app, kit, "look/rounded", .square_multiple, "Rounded corners", if (ten) "Windows 10's are square" else "Menus, flyouts, the start menu and the controls in apps", &look.rounded_corners, ten);
    lookCard(app, kit, "look/windows", .window, "Rounded window corners", if (ten) "Windows 10's are square" else "The corners of every window", &look.window_corners, ten);
    lookCard(app, kit, "look/floating", .tab_desktop, "Floating panels", if (ten) "Windows 10's sit against the taskbar" else "Start, search, quick settings and notifications float clear of the taskbar; off, they sit against it", &look.floating, ten);
    lookCard(app, kit, "look/transparency", .eye, "Transparency effects", "Windows and surfaces appear translucent", &look.transparency, false);
    lookCard(app, kit, "look/animations", .play, "Animation effects", "Windows, menus and panels move; off, they are where they go at once - lighter, for games too", &look.animations, false);

    // What title bars are made of, and the glass of the apps that ask for
    // it - Settings among them.
    const s = &app.personalization_state;
    const solid = !look.transparency;
    kit.section("Materials");
    kit.cardBegin("look/title-bars", .{ .icon = .window, .title = "Title bars", .description = if (solid) "Solid with transparency effects off" else "The title bars the desktop draws - automatic follows an app's own backdrop. Apps that draw their own, like most GNOME apps, keep theirs" });
    if (!s.title_material_choice.open) s.title_material_choice.selected = @intFromEnum(look.title_bars);
    if (!solid) if (kit.dropdown("look/title-bars/list", &s.title_material_choice, &.{ "Automatic", "Solid", "Mica", "Acrylic" }, .fixed(160))) {
        look.title_bars = @enumFromInt(s.title_material_choice.selected);
        app.save();
    };
    _ = kit.cardEnd(false);
    kit.cardBegin("look/windows", .{ .icon = .square_multiple, .title = "App backdrop", .description = if (solid) "Solid with transparency effects off" else "For apps that ask for it, like Settings: automatic is Mica in Windows 11's look, acrylic in Windows 10's" });
    if (!s.window_material_choice.open) s.window_material_choice.selected = @intFromEnum(look.windows);
    if (!solid) if (kit.dropdown("look/windows/list", &s.window_material_choice, &.{ "Automatic", "Solid", "Mica", "Acrylic" }, .fixed(160))) {
        look.windows = @enumFromInt(s.window_material_choice.selected);
        app.save();
    };
    _ = kit.cardEnd(false);
}

fn lookCard(app: *Settings, kit: *Kit, id: []const u8, icon: widgets.icons.Name, title: []const u8, description: []const u8, value: *bool, disabled: bool) void {
    kit.cardBegin(id, .{ .icon = icon, .title = title, .description = description });
    // What it would be is shown greyed: Windows 10's is off.
    var shown = value.* and !disabled;
    if (kit.toggle(kit.print("{s}/toggle", .{id}), if (disabled) &shown else value, .{ .disabled = disabled })) {
        app.save();
        app.rethemeSoon();
    }
    _ = kit.cardEnd(false);
}

/// One of the two looks to choose, as a picture of a desktop in it.
fn styleCard(app: *Settings, kit: *Kit, style: Store.Look.Style, title: []const u8, description: []const u8) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const m = kit.theme.metrics;
    const id = kit.print("style/{t}", .{style});
    const chosen = app.store.look.style == style;
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .grow,
        .direction = .top_to_bottom,
        .padding = .all(8),
        .gap = 10,
        .background_color = if (hovered) p.control_secondary else p.card,
        .corner_radius = .all(m.overlay_radius),
        .border = if (chosen) .{ .color = p.accent, .width = .all(2) } else .{ .color = p.card_stroke, .width = .all(1) },
        .focus = .{},
    });
    defer u.close();
    preview(kit, style);
    {
        u.open(.{ .width = .grow, .gap = 10, .padding = .xy(4, 2), .align_y = .center });
        defer u.close();
        // The choice's mark: a filled circle with a tick, or a ring.
        u.open(.{
            .width = .fixed(20),
            .height = .fixed(20),
            .corner_radius = .all(10),
            .background_color = if (chosen) p.accent else .transparent,
            .border = if (chosen) null else .{ .color = p.control_strong_stroke, .width = .all(1) },
            .align_x = .center,
            .align_y = .center,
        });
        if (chosen) kit.icon(.checkmark, 12, p.text_on_accent, .regular);
        u.close();
        u.open(.{ .width = .grow, .direction = .top_to_bottom });
        defer u.close();
        kit.text(title, .body_strong, p.text_primary);
        kit.text(description, .caption, p.text_secondary);
    }
    if (u.justReleased() and !chosen) {
        app.store.look.style = style;
        app.save();
        app.rethemeSoon();
    }
}

/// A desktop in the look `style`, small: the wallpaper, a window, the
/// taskbar and the start menu open over it, each as that Windows has it.
/// Drawn with its own corners, whatever the look in use.
fn preview(kit: *Kit, style: Store.Look.Style) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const accent = kit.theme.accent;
    const dark = kit.theme.mode == .dark;
    const eleven = style == .win11;
    const r: f32 = if (eleven) 4 else 0;
    const base = if (dark) widgets.argb(0xFF202020) else widgets.argb(0xFFF3F3F3);
    const bar = if (dark) widgets.argb(0xFF1C1C1C) else widgets.argb(0xFFEEEEEE);
    const ink = if (dark) widgets.argb(0xFFFFFFFF) else widgets.argb(0xFF1A1A1A);
    u.open(.{
        .width = .grow,
        .height = .fixed(156),
        .direction = .top_to_bottom,
        .corner_radius = .all(4),
        .keep_corners = true,
        .clip = .both,
        .background_color = accent.dark2,
        .gradient = .{ .to = accent.light1, .toward = .right },
    });
    defer u.close();

    // A window, a little way in.
    u.open(.{
        .width = .fixed(150),
        .height = .fixed(84),
        .direction = .top_to_bottom,
        .corner_radius = .all(r),
        .keep_corners = true,
        .background_color = base,
        .border = .{ .color = if (eleven) ink.withAlpha(0.12) else accent.base, .width = .all(1) },
        .floating = .{ .offset = .{ .x = if (eleven) 70 else 120, .y = 14 }, .clip = .like_children },
    });
    {
        // Its title bar and the close button: Windows 10's red square.
        u.open(.{ .width = .grow, .height = .fixed(12), .align_y = .center, .padding = .trbl(0, 0, 0, 6), .gap = 3 });
        u.empty(.{ .width = .fixed(18), .height = .fixed(3), .corner_radius = .all(1.5), .keep_corners = true, .background_color = ink.withAlpha(0.5) });
        u.empty(.{ .width = .grow });
        u.empty(.{ .width = .fixed(14), .height = .fixed(12), .background_color = if (eleven) .transparent else widgets.argb(0xFFE81123), .corner_radius = .corners(0, r, 0, 0), .keep_corners = true });
        u.close();
        u.open(.{ .width = .grow, .height = .grow, .padding = .all(6), .gap = 4, .direction = .top_to_bottom });
        for (0..3) |i| u.empty(.{
            .width = .fixed(@as(f32, if (i == 0) 90 else 60)),
            .height = .fixed(5),
            .corner_radius = .all(if (eleven) 2.5 else 0),
            .keep_corners = true,
            .background_color = ink.withAlpha(if (i == 0) 0.35 else 0.18),
        });
        u.close();
    }
    u.close();

    // The start menu: Windows 11's floats in the middle; Windows 10's sits
    // in the corner on the taskbar, its tiles in the accent.
    u.open(.{
        .width = .fixed(if (eleven) 92 else 104),
        .height = .fixed(if (eleven) 96 else 108),
        .direction = if (eleven) .top_to_bottom else .left_to_right,
        .padding = .all(6),
        .gap = 4,
        .corner_radius = .all(r * 1.5),
        .keep_corners = true,
        .background_color = bar.withAlpha(0.97),
        .border = if (eleven) .{ .color = ink.withAlpha(0.1), .width = .all(1) } else null,
        .shadow = if (eleven) .{ .color = widgets.argb(0x50000000), .blur = 10, .offset = .{ .x = 0, .y = 3 } } else null,
        .floating = if (eleven)
            .{ .fractions = .{ .element_x = 0.5, .element_y = 1, .target_x = 0.5, .target_y = 1 }, .offset = .{ .x = 0, .y = -22 }, .z_index = 1, .clip = .like_children }
        else
            .{ .fractions = .{ .element_x = 0, .element_y = 1, .target_x = 0, .target_y = 1 }, .offset = .{ .x = 0, .y = -14 }, .z_index = 1, .clip = .like_children },
    });
    if (eleven) {
        // A search field, and a grid of pinned apps.
        u.empty(.{ .width = .grow, .height = .fixed(8), .corner_radius = .all(4), .keep_corners = true, .background_color = ink.withAlpha(0.08), .border = .{ .color = ink.withAlpha(0.12), .width = .all(1) } });
        u.open(.{ .width = .grow, .wrap = true, .gap = 6, .wrap_gap = 6, .padding = .xy(4, 4) });
        for (0..12) |i| u.empty(.{
            .width = .fixed(10),
            .height = .fixed(10),
            .corner_radius = .all(2),
            .keep_corners = true,
            .background_color = if (i % 3 == 0) accent.light1 else if (i % 3 == 1) ink.withAlpha(0.35) else accent.base,
        });
        u.close();
    } else {
        // The app list, and the tiles.
        u.open(.{ .width = .fixed(30), .height = .grow, .direction = .top_to_bottom, .gap = 4 });
        for (0..7) |_| u.empty(.{ .width = .grow, .height = .fixed(4), .background_color = ink.withAlpha(0.3) });
        u.close();
        u.open(.{ .width = .grow, .wrap = true, .gap = 2, .wrap_gap = 2 });
        for (0..9) |i| u.empty(.{
            .width = .fixed(if (i == 0) 42 else 20),
            .height = .fixed(20),
            .background_color = if (i % 2 == 0) accent.base else accent.dark1,
        });
        u.close();
    }
    u.close();

    // The taskbar along the bottom.
    u.open(.{
        .width = .grow,
        .height = .fixed(if (eleven) 16 else 14),
        .gap = 4,
        .align_y = .center,
        .padding = .xy(4, 0),
        .background_color = bar,
        .floating = .{ .fractions = .{ .element_x = 0, .element_y = 1, .target_x = 0, .target_y = 1 }, .z_index = 2, .clip = .like_children },
    });
    defer u.close();
    if (eleven) u.empty(.{ .width = .grow });
    // Start: the desktop's own mark, three bars of light, in either look.
    {
        u.open(.{ .width = .fixed(9), .height = .fixed(8), .direction = .top_to_bottom, .gap = 1, .align_y = .center });
        defer u.close();
        for ([_]f32{ 9, 6.5, 4 }) |w| u.empty(.{ .width = .fixed(w), .height = .fixed(2), .corner_radius = .all(1), .keep_corners = true, .background_color = accent.light1 });
    }
    // Windows 10's search box beside it.
    if (!eleven) u.empty(.{ .width = .fixed(50), .height = .fixed(10), .background_color = if (dark) widgets.argb(0xFF3A3A3A) else widgets.argb(0xFFFFFFFF), .border = .{ .color = ink.withAlpha(0.2), .width = .all(1) } });
    for (0..5) |i| {
        u.open(.{ .direction = .top_to_bottom, .align_x = .center, .gap = 1 });
        u.empty(.{ .width = .fixed(8), .height = .fixed(8), .corner_radius = .all(if (eleven) 2 else 0), .keep_corners = true, .background_color = if (i == 1) accent.base else ink.withAlpha(0.45) });
        // The running app's mark: Windows 11's short pill, Windows 10's
        // bar across the button.
        if (i == 1) u.empty(.{ .width = .fixed(if (eleven) 4 else 10), .height = .fixed(1.5), .corner_radius = .all(0.75), .keep_corners = true, .background_color = accent.light1 });
        u.close();
    }
    u.empty(.{ .width = .grow });
    // The clock - and Windows 10's Action Center button past it.
    u.empty(.{ .width = .fixed(14), .height = .fixed(4), .background_color = ink.withAlpha(0.5) });
    if (!eleven) u.empty(.{ .width = .fixed(6), .height = .fixed(6), .background_color = ink.withAlpha(0.5) });
    _ = p;
}

const interval_names = [_][]const u8{ "1 minute", "10 minutes", "30 minutes", "1 hour", "6 hours", "1 day" };
const interval_minutes = [_]u32{ 1, 10, 30, 60, 360, 1440 };

fn background(app: *Settings, kit: *Kit) void {
    const s = &app.personalization_state;
    const store = &app.store;
    // A picture, or a slideshow - as Windows' "Personalize your background".
    kit.cardBegin("bg/kind", .{ .icon = .image, .title = "Personalize your background", .description = "A picture, or a slideshow of a folder's pictures" });
    if (!s.background_choice.open) s.background_choice.selected = @intFromEnum(store.background);
    if (kit.dropdown("bg/kind/list", &s.background_choice, &.{ "Picture", "Slideshow" }, .fixed(160))) {
        store.background = @enumFromInt(s.background_choice.selected);
        app.save();
    }
    _ = kit.cardEnd(false);
    if (store.background == .slideshow) return slideshow(app, kit);

    kit.cardBegin("bg/browse", .{ .icon = .folder_open, .title = "Choose a photo", .description = store.wallpaper() orelse "Any picture of yours" });
    if (kit.button("bg/browse/button", "Browse photos", .{})) app.choose(.picture, "Choose a picture");
    _ = kit.cardEnd(false);
    pictureGrid(app, kit);
}

/// A slideshow: its folder, how often it changes, and in what order.
fn slideshow(app: *Settings, kit: *Kit) void {
    const s = &app.personalization_state;
    const store = &app.store;
    kit.cardBegin("bg/album", .{ .icon = .image_multiple, .title = "Choose a picture album for your slideshow", .description = store.slideshowFolder() orelse "Pictures" });
    if (kit.button("bg/album/button", "Browse", .{})) app.choose(.folder, "Choose a folder of pictures");
    _ = kit.cardEnd(false);
    kit.cardBegin("bg/interval", .{ .icon = .timer, .title = "Change picture every" });
    if (!s.interval_choice.open) s.interval_choice.selected = for (interval_minutes, 0..) |m, i| {
        if (m >= store.slideshow_minutes) break i;
    } else interval_minutes.len - 1;
    if (kit.dropdown("bg/interval/list", &s.interval_choice, &interval_names, .fixed(160))) {
        store.slideshow_minutes = interval_minutes[s.interval_choice.selected];
        app.save();
    }
    _ = kit.cardEnd(false);
    kit.cardBegin("bg/shuffle", .{ .icon = .arrow_sync, .title = "Shuffle the picture order" });
    if (kit.toggle("bg/shuffle/toggle", &store.slideshow_shuffle, .{})) app.save();
    _ = kit.cardEnd(false);
}

fn pictureGrid(app: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    kit.section("Recent images");
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
        app.rethemeSoon();
    }
    _ = kit.cardEnd(false);

    kit.cardBegin("accent", .{ .icon = .color, .title = "Accent color", .description = "Used for buttons, switches and selections" });
    _ = kit.cardEnd(false);
    {
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
                app.rethemeSoon();
            }
            u.close();
        }
    }
    // Both Windows offer it, off at first.
    kit.cardBegin("accent/title-bars", .{ .icon = .window, .title = "Show accent color on title bars and window borders", .description = "The window in front's, where the desktop draws them" });
    if (kit.toggle("accent/title-bars/toggle", &app.store.look.accent_title_bars, .{})) app.save();
    _ = kit.cardEnd(false);
}
