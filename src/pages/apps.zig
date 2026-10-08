// SPDX-License-Identifier: BSD-2-Clause

//! Apps: the apps installed, found by name, each opened from here.

const std = @import("std");

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");
const apps_mod = @import("../apps.zig");

pub fn draw(app: *Settings, kit: *Kit) void {
    if (app.sub == .none) {
        app.linkCard(kit, .installed, .apps_list, "The apps on this device");
        return;
    }
    installed(app, kit);
}

fn installed(app: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const list = if (app.apps) |a| a.list else &.{};
    {
        u.open(.{ .width = .grow, .padding = .trbl(0, 0, 8, 0), .gap = 12, .align_y = .center });
        defer u.close();
        kit.textField("apps/search", .{ .placeholder = "Search apps", .width = .fixed(320), .icon = .search });
        u.empty(.{ .width = .grow });
        kit.label(kit.print("{d} apps found", .{list.len}), .body, p.text_secondary);
    }
    const query = u.textValueOf("apps/search") orelse "";
    for (list, 0..) |*a, i| {
        if (query.len > 0 and apps_mod.score(a, query) == null) continue;
        const id = kit.print("apps/{d}", .{i});
        u.open(.{
            .id = id,
            .width = .grow,
            .height = .fixed(64),
            .padding = .xy(16, 0),
            .gap = 16,
            .align_y = .center,
            .corner_radius = .all(4),
            .background_color = p.card,
            .border = .{ .color = p.card_stroke, .width = .all(1) },
        });
        defer u.close();
        if (app.window.icons.lookup(a.icon, 32)) |texture| {
            u.empty(.{ .width = .fixed(32), .height = .fixed(32), .image = .{ .texture = texture } });
        } else kit.icon(.apps, 32, p.text_secondary, .regular);
        {
            u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2 });
            defer u.close();
            kit.label(a.name, .body, p.text_primary);
            const detail = if (a.generic_name.len > 0) a.generic_name else a.id;
            kit.label(detail, .caption, p.text_secondary);
        }
        if (kit.button(kit.print("apps/{d}/open", .{i}), "Open", .{})) apps_mod.launch(app.gpa, app.io, a, null, null);
    }
}
