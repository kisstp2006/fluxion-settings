// SPDX-License-Identifier: BSD-2-Clause

//! Display: as Windows 11's - the screens side by side where there are
//! several, the brightness and the night light, then Scale & layout: how
//! big everything is drawn (100 %, 125 %, 150 % … with the one recommended
//! for the screen marked), the resolution and which way round it is; and,
//! a page further, the screen's particulars and its refresh rate.
//!
//! **A scale is taken at once**, as Windows takes one. A resolution, a turn
//! or a refresh rate may leave nothing to see by, so the screen changes and
//! a question comes up over the page - *Keep these display settings?* -
//! going back as it was after fifteen seconds unless it is kept.
//!
//! What a screen was set to is kept under its connector in `settings.ini`,
//! where the compositor looks when the screen comes:
//!
//! ```ini
//! [output HDMI-A-1]
//! scale=1.5
//! mode=3840x2160@60
//! transform=normal
//! ```

const std = @import("std");
const xkb = @import("xkbcommon");
const wl = @import("wayland").client.wl;

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");
const Store = @import("../Store.zig");
const Displays = @import("../Displays.zig");
const Motion = @import("../Motion.zig");
const Window = @import("../Window.zig");
const system_page = @import("system.zig");

/// How long a new mode stays without being kept: Windows' fifteen seconds.
const keep_seconds = 15;

pub const State = struct {
    /// The screen being set, by its connector: the first until another is
    /// chosen.
    chosen: Displays.Text = .{},
    choose: Kit.Dropdown = .{},
    scale: Kit.Dropdown = .{},
    resolution: Kit.Dropdown = .{},
    orientation: Kit.Dropdown = .{},
    refresh: Kit.Dropdown = .{},
    /// A mode, a turn or a rate changed and not yet kept.
    pending: ?Pending = null,
    /// The question coming up.
    dialog_motion: Motion = .{ .duration = 250, .ease = .decelerate },
    /// The last change the compositor would not take, and when.
    refused_ms: i64 = 0,
    /// Room for the names the drop-downs show, filled again each drawing.
    names: [4096]u8 = undefined,
    names_used: usize = 0,

    fn name(self: *State, comptime format: []const u8, args: anytype) []const u8 {
        const out = std.fmt.bufPrint(self.names[self.names_used..], format, args) catch return "";
        self.names_used += out.len;
        return out;
    }
};

/// What a screen was, to go back to; and what it is now, to keep.
const Pending = struct {
    head: Displays.Text = .{},
    before: Setup,
    after: Setup,
    deadline_ms: i64,
};

const Setup = struct {
    width: i32,
    height: i32,
    refresh: i32,
    transform: wl.Output.Transform,
};

const orientations = [_]struct { name: []const u8, transform: wl.Output.Transform }{
    .{ .name = "Landscape", .transform = .normal },
    .{ .name = "Portrait", .transform = .@"90" },
    .{ .name = "Landscape (flipped)", .transform = .@"180" },
    .{ .name = "Portrait (flipped)", .transform = .@"270" },
};

pub fn opened(app: *Settings) void {
    // The brightness and the night light, as System reads them.
    system_page.opened(app);
}

/// The compositor told of the screens again: the one chosen still there,
/// or the first.
pub fn displaysChanged(app: *Settings) void {
    const s = &app.display_state;
    if (chosenHead(app) == null) {
        if (app.displays) |d| if (d.list().len > 0) s.chosen.set(d.list()[0].name.get());
    }
    if (app.displays) |d| if (d.outcome == .failed) {
        s.refused_ms = Window.nowMs();
        d.outcome = .none;
        // What was not taken is not asked about.
        s.pending = null;
    };
}

fn chosenHead(app: *Settings) ?*Displays.Head {
    const d = app.displays orelse return null;
    const s = &app.display_state;
    for (d.list()) |head| if (std.mem.eql(u8, head.name.get(), s.chosen.get())) return head;
    if (d.list().len > 0) {
        s.chosen.set(d.list()[0].name.get());
        return d.list()[0];
    }
    return null;
}

pub fn draw(app: *Settings, kit: *Kit) void {
    const s = &app.display_state;
    s.names_used = 0;
    const d = app.displays;
    const head = chosenHead(app);
    if (d) |displays| if (displays.list().len > 1) arrangement(app, kit, displays);
    system_page.brightnessAndColor(app, kit);

    kit.section("Scale & layout");
    if (head) |h| {
        scale(app, kit, h);
        resolution(app, kit, h);
        orientation(app, kit, h);
    } else {
        Settings.infoCard(kit, "display/none", .desktop, "Display", "This desktop does not say what screens there are");
    }
    if (s.refused_ms != 0 and Window.nowMs() - s.refused_ms < 8000) {
        kit.cardBegin("display/refused", .{ .icon = .warning, .title = "That setting couldn't be applied", .description = "The display didn't take it; nothing was changed" });
        _ = kit.cardEnd(false);
    }

    kit.section("Related settings");
    app.linkCard(kit, .advanced_display, .desktop_pulse, "Display information, refresh rate");
}

/// The screens side by side, as they are placed, numbered; a click chooses
/// the one the cards below set.
fn arrangement(app: *Settings, kit: *Kit, d: *Displays) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const s = &app.display_state;
    const heads = d.list();
    // The whole of them, in the layout's pixels.
    var x0: f32 = std.math.floatMax(f32);
    var y0: f32 = std.math.floatMax(f32);
    var x1: f32 = -std.math.floatMax(f32);
    var y1: f32 = -std.math.floatMax(f32);
    for (heads) |h| {
        if (!h.enabled) continue;
        const size = h.turnedSize();
        const w = @as(f32, @floatFromInt(size[0])) / @as(f32, @floatCast(h.scale));
        const hh = @as(f32, @floatFromInt(size[1])) / @as(f32, @floatCast(h.scale));
        x0 = @min(x0, @as(f32, @floatFromInt(h.position[0])));
        y0 = @min(y0, @as(f32, @floatFromInt(h.position[1])));
        x1 = @max(x1, @as(f32, @floatFromInt(h.position[0])) + w);
        y1 = @max(y1, @as(f32, @floatFromInt(h.position[1])) + hh);
    }
    if (x1 <= x0 or y1 <= y0) return;
    const area_h: f32 = 180;
    const area_w: f32 = 560;
    const fit = @min((area_w - 40) / (x1 - x0), (area_h - 40) / (y1 - y0));
    const ox = (area_w - (x1 - x0) * fit) / 2;
    const oy = (area_h - (y1 - y0) * fit) / 2;

    u.open(.{ .width = .grow, .height = .fixed(area_h + 24), .align_x = .center, .padding = .trbl(12, 0, 12, 0) });
    defer u.close();
    u.open(.{ .width = .fixed(area_w), .height = .fixed(area_h) });
    defer u.close();
    for (heads, 1..) |h, number| {
        if (!h.enabled) continue;
        const size = h.turnedSize();
        const w = @as(f32, @floatFromInt(size[0])) / @as(f32, @floatCast(h.scale)) * fit;
        const hh = @as(f32, @floatFromInt(size[1])) / @as(f32, @floatCast(h.scale)) * fit;
        const x = ox + (@as(f32, @floatFromInt(h.position[0])) - x0) * fit;
        const y = oy + (@as(f32, @floatFromInt(h.position[1])) - y0) * fit;
        const id = kit.print("display/screen/{d}", .{number});
        const chosen = std.mem.eql(u8, h.name.get(), s.chosen.get());
        const hovered = u.isPointerOver(id);
        u.open(.{
            .id = id,
            .width = .fixed(w - 4),
            .height = .fixed(hh - 4),
            .align_x = .center,
            .align_y = .center,
            .corner_radius = .all(4),
            .background_color = if (chosen) p.accent else if (hovered) p.control_secondary else p.control,
            .border = .{ .color = if (chosen) p.accent else p.control_stroke, .width = .all(if (chosen) 2 else 1) },
            .floating = .{ .attach = .parent, .offset = .{ .x = x + 2, .y = y + 2 }, .clip = .like_children },
        });
        kit.label(kit.print("{d}", .{number}), .title, if (chosen) p.text_on_accent else p.text_primary);
        if (u.justReleased()) s.chosen.set(h.name.get());
        u.close();
    }
}

fn scale(app: *Settings, kit: *Kit, head: *Displays.Head) void {
    const s = &app.display_state;
    kit.cardBegin("display/scale", .{ .icon = .zoom_in, .title = "Scale", .description = "Change the size of text, apps, and other items" });
    var names: [24][]const u8 = undefined;
    var values: [24]f64 = undefined;
    var n: usize = 0;
    const recommended = head.recommendedScale();
    const most = @max(head.largestScale(), @max(recommended, head.scale));
    var v: f64 = 1;
    while (v <= most + 0.001 and n < names.len - 1) : (v += 0.25) {
        const percent: u32 = @intFromFloat(@round(v * 100));
        names[n] = if (@abs(v - recommended) < 0.01) s.name("{d}% (Recommended)", .{percent}) else s.name("{d}%", .{percent});
        values[n] = v;
        n += 1;
    }
    // A scale set elsewhere that is none of these: shown as it is.
    var current: ?usize = null;
    for (values[0..n], 0..) |value, i| if (@abs(value - head.scale) < 0.01) {
        current = i;
    };
    if (current == null) {
        names[n] = s.name("Custom: {d}%", .{@as(u32, @intFromFloat(@round(head.scale * 100)))});
        values[n] = head.scale;
        current = n;
        n += 1;
    }
    if (!s.scale.open) s.scale.selected = current.?;
    if (kit.dropdown("display/scale/choice", &s.scale, names[0..n], .fixed(240))) {
        const want = values[s.scale.selected];
        if (app.displays) |d| d.apply(head, .{ .scale = want });
        var buffer: [32]u8 = undefined;
        keep(app, head, "scale", std.fmt.bufPrint(&buffer, "{d}", .{want}) catch return);
    }
    _ = kit.cardEnd(false);
}

fn resolution(app: *Settings, kit: *Kit, head: *Displays.Head) void {
    const s = &app.display_state;
    kit.cardBegin("display/resolution", .{ .icon = .full_screen_maximize, .title = "Display resolution", .description = "Adjust the resolution to fit your connected display" });
    defer _ = kit.cardEnd(false);
    const current = head.current orelse return;
    const preferred = head.preferredMode();
    // Each size once, the largest first.
    var sizes: [48][2]i32 = undefined;
    var n: usize = 0;
    for (head.modes.items) |m| {
        const seen = for (sizes[0..n]) |size| {
            if (size[0] == m.width and size[1] == m.height) break true;
        } else false;
        if (seen or n == sizes.len) continue;
        sizes[n] = .{ m.width, m.height };
        n += 1;
    }
    std.mem.sort([2]i32, sizes[0..n], {}, struct {
        fn larger(_: void, a: [2]i32, b: [2]i32) bool {
            return @as(i64, a[0]) * a[1] > @as(i64, b[0]) * b[1];
        }
    }.larger);
    var names: [48][]const u8 = undefined;
    var selected: usize = 0;
    for (sizes[0..n], 0..) |size, i| {
        const is_preferred = if (preferred) |m| m.width == size[0] and m.height == size[1] else false;
        names[i] = if (is_preferred) s.name("{d} × {d} (Recommended)", .{ size[0], size[1] }) else s.name("{d} × {d}", .{ size[0], size[1] });
        if (size[0] == current.width and size[1] == current.height) selected = i;
    }
    if (!s.resolution.open) s.resolution.selected = selected;
    if (kit.dropdown("display/resolution/choice", &s.resolution, names[0..n], .fixed(240))) {
        const size = sizes[s.resolution.selected];
        // At the rate it is at now, or the nearest it has at that size.
        var best: ?*Displays.Mode = null;
        for (head.modes.items) |m| {
            if (m.width != size[0] or m.height != size[1]) continue;
            if (best == null or @abs(m.refresh - current.refresh) < @abs(best.?.refresh - current.refresh)) best = m;
        }
        if (best) |m| change(app, head, .{ .mode = m });
    }
}

fn orientation(app: *Settings, kit: *Kit, head: *Displays.Head) void {
    const s = &app.display_state;
    kit.cardBegin("display/orientation", .{ .icon = .rotate_right, .title = "Display orientation" });
    var names: [orientations.len][]const u8 = undefined;
    var selected: usize = 0;
    for (orientations, 0..) |o, i| {
        names[i] = o.name;
        if (o.transform == head.transform) selected = i;
    }
    if (!s.orientation.open) s.orientation.selected = selected;
    if (kit.dropdown("display/orientation/choice", &s.orientation, &names, .fixed(240))) {
        change(app, head, .{ .transform = orientations[s.orientation.selected].transform });
    }
    _ = kit.cardEnd(false);
}

/// Advanced display: which screen, what it is, and its refresh rate.
pub fn advanced(app: *Settings, kit: *Kit) void {
    const s = &app.display_state;
    s.names_used = 0;
    const d = app.displays orelse return;
    const heads = d.list();
    if (heads.len > 1) {
        kit.cardBegin("advanced/choose", .{ .icon = .desktop, .title = "Select a display to view or change its settings" });
        var names: [8][]const u8 = undefined;
        var selected: usize = 0;
        const shown = @min(heads.len, names.len);
        for (heads[0..shown], 0..) |h, i| {
            names[i] = s.name("Display {d}: {s}", .{ i + 1, h.name.get() });
            if (std.mem.eql(u8, h.name.get(), s.chosen.get())) selected = i;
        }
        if (!s.choose.open) s.choose.selected = selected;
        if (kit.dropdown("advanced/choose/choice", &s.choose, names[0..shown], .fixed(260))) s.chosen.set(heads[s.choose.selected].name.get());
        _ = kit.cardEnd(false);
    }
    const head = chosenHead(app) orelse return;

    kit.section("Display information");
    var title_buffer: [160]u8 = undefined;
    Settings.infoCard(kit, "advanced/name", .desktop, head.title(&title_buffer), s.name("Connected to {s}", .{head.name.get()}));
    if (head.current) |m| {
        const size = head.turnedSize();
        Settings.infoCard(kit, "advanced/desktop", null, "Desktop mode", s.name("{d} × {d}, {d:.2} Hz", .{ size[0], size[1], m.hz() }));
        Settings.infoCard(kit, "advanced/signal", null, "Active signal mode", s.name("{d} × {d}, {d:.2} Hz", .{ m.width, m.height, m.hz() }));
    }
    if (head.physical[0] > 0 and head.physical[1] > 0) {
        const mw: f32 = @floatFromInt(head.physical[0]);
        const mh: f32 = @floatFromInt(head.physical[1]);
        const inches = @sqrt(mw * mw + mh * mh) / 25.4;
        Settings.infoCard(kit, "advanced/size", null, "Screen size", s.name("{d:.1}\" ({d} × {d} mm)", .{ inches, head.physical[0], head.physical[1] }));
    }
    Settings.infoCard(kit, "advanced/scale", null, "Scale", s.name("{d}%", .{@as(u32, @intFromFloat(@round(head.scale * 100)))}));

    kit.section("Refresh rate");
    refreshRate(app, kit, head);
}

fn refreshRate(app: *Settings, kit: *Kit, head: *Displays.Head) void {
    const s = &app.display_state;
    kit.cardBegin("advanced/refresh", .{ .icon = .desktop_pulse, .title = "Choose a refresh rate", .description = "A higher rate gives smoother motion, but also uses more power" });
    defer _ = kit.cardEnd(false);
    const current = head.current orelse return;
    var modes: [32]*Displays.Mode = undefined;
    var n: usize = 0;
    for (head.modes.items) |m| {
        if (m.width != current.width or m.height != current.height or n == modes.len) continue;
        const seen = for (modes[0..n]) |o| {
            if (@abs(o.refresh - m.refresh) < 10) break true;
        } else false;
        if (seen) continue;
        modes[n] = m;
        n += 1;
    }
    std.mem.sort(*Displays.Mode, modes[0..n], {}, struct {
        fn faster(_: void, a: *Displays.Mode, b: *Displays.Mode) bool {
            return a.refresh > b.refresh;
        }
    }.faster);
    var names: [32][]const u8 = undefined;
    var selected: usize = 0;
    for (modes[0..n], 0..) |m, i| {
        names[i] = s.name("{d:.2} Hz", .{m.hz()});
        if (m == current) selected = i;
    }
    if (n == 0) return;
    if (!s.refresh.open) s.refresh.selected = selected;
    if (kit.dropdown("advanced/refresh/choice", &s.refresh, names[0..n], .fixed(200))) change(app, head, .{ .mode = modes[s.refresh.selected] });
}

/// Change what may leave nothing to see by - the mode, the turn - and ask,
/// over the page, whether to keep it.
fn change(app: *Settings, head: *Displays.Head, what: Displays.Change) void {
    const d = app.displays orelse return;
    const s = &app.display_state;
    const now = head.current orelse return;
    const before: Setup = .{ .width = now.width, .height = now.height, .refresh = now.refresh, .transform = head.transform };
    var after = before;
    if (what.mode) |m| {
        after.width = m.width;
        after.height = m.height;
        after.refresh = m.refresh;
    }
    if (what.transform) |t| after.transform = t;
    if (std.meta.eql(before, after)) return;
    d.apply(head, what);
    // Asked again before the last was kept: back to where it began.
    const start = if (s.pending) |p| p.before else before;
    s.pending = .{ .before = start, .after = after, .deadline_ms = Window.nowMs() + keep_seconds * 1000 };
    s.pending.?.head.set(head.name.get());
    s.dialog_motion.begin();
    app.window.redraw();
}

/// Keep `key` for `head`, where the compositor looks when the screen comes.
fn keep(app: *Settings, head: *const Displays.Head, key_name: []const u8, value: []const u8) void {
    var section_buffer: [160]u8 = undefined;
    const section = std.fmt.bufPrint(&section_buffer, "output {s}", .{head.name.get()}) catch return;
    Store.writeKey(app.io, section, key_name, value);
}

fn keepChanges(app: *Settings) void {
    const s = &app.display_state;
    const pending = s.pending orelse return;
    s.pending = null;
    const d = app.displays orelse return;
    for (d.list()) |head| {
        if (!std.mem.eql(u8, head.name.get(), pending.head.get())) continue;
        var buffer: [48]u8 = undefined;
        const a = pending.after;
        keep(app, head, "mode", std.fmt.bufPrint(&buffer, "{d}x{d}@{d:.3}", .{ a.width, a.height, @as(f32, @floatFromInt(a.refresh)) / 1000 }) catch return);
        keep(app, head, "transform", transformName(a.transform));
    }
    app.window.redraw();
}

fn revert(app: *Settings) void {
    const s = &app.display_state;
    const pending = s.pending orelse return;
    s.pending = null;
    const d = app.displays orelse return;
    for (d.list()) |head| {
        if (!std.mem.eql(u8, head.name.get(), pending.head.get())) continue;
        const b = pending.before;
        var best: ?*Displays.Mode = null;
        for (head.modes.items) |m| {
            if (m.width != b.width or m.height != b.height) continue;
            if (best == null or @abs(m.refresh - b.refresh) < @abs(best.?.refresh - b.refresh)) best = m;
        }
        d.apply(head, .{ .mode = best, .transform = b.transform });
    }
    app.window.redraw();
}

fn transformName(t: wl.Output.Transform) []const u8 {
    return switch (t) {
        .normal => "normal",
        .@"90" => "90",
        .@"180" => "180",
        .@"270" => "270",
        .flipped => "flipped",
        .flipped_90 => "flipped-90",
        .flipped_180 => "flipped-180",
        .flipped_270 => "flipped-270",
        _ => "normal",
    };
}

/// Enter keeps the new mode, Escape goes back, while the question is up.
pub fn key(app: *Settings, sym: xkb.Keysym) bool {
    if (app.display_state.pending == null) return false;
    switch (@intFromEnum(sym)) {
        xkb.Keysym.Return, xkb.Keysym.KP_Enter => keepChanges(app),
        xkb.Keysym.Escape => revert(app),
        else => return false,
    }
    return true;
}

/// *Keep these display settings?* - over the whole window, the rest dimmed,
/// counting down to going back.
pub fn keepDialog(app: *Settings, kit: *Kit) void {
    const s = &app.display_state;
    const pending = s.pending orelse return;
    const now = Window.nowMs();
    const left_ms = pending.deadline_ms - now;
    if (left_ms <= 0) {
        revert(app);
        return;
    }
    // Woken for the next second, though nothing else happens.
    app.window.wakeAt(now + @mod(left_ms, 1000) + 1);
    const seconds = @divTrunc(left_ms + 999, 1000);

    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = s.dialog_motion.progress();
    if (s.dialog_motion.running()) app.window.redraw();
    u.open(.{
        .id = "keep/smoke",
        .width = .grow,
        .height = .grow,
        .align_x = .center,
        .align_y = .center,
        .background_color = p.smoke.withAlpha(p.smoke.a * s.dialog_motion.fade(0, 167)),
        .floating = .{ .attach = .root, .z_index = 200 },
    });
    defer u.close();
    u.open(.{
        .id = "keep/dialog",
        .width = .fixed(448),
        .direction = .top_to_bottom,
        .background_color = p.solid_base,
        .corner_radius = .all(8),
        .border = .{ .color = p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.window),
        .opacity = s.dialog_motion.fade(0, 83),
        .scale = .by(Motion.mix(1.05, 1, t)),
    });
    defer u.close();
    {
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .all(24), .gap = 12, .background_color = p.layer, .corner_radius = .corners(8, 8, 0, 0) });
        defer u.close();
        kit.label("Keep these display settings?", .subtitle, p.text_primary);
        var style = kit.style(.body, p.text_primary);
        style.wrap = .words;
        u.text(kit.print("Reverting to previous display settings in {d} second{s}.", .{ seconds, if (seconds == 1) "" else "s" }), style);
    }
    {
        u.open(.{ .width = .grow, .padding = .all(24), .gap = 8 });
        defer u.close();
        if (kit.button("keep/yes", "Keep changes", .{ .kind = .accent, .width = .grow })) keepChanges(app);
        if (kit.button("keep/no", "Revert", .{ .width = .grow })) revert(app);
    }
}
