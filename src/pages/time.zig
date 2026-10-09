// SPDX-License-Identifier: BSD-2-Clause

//! Time & language: the date and the time, the time zone, the language
//! and the keyboard layout - as the system has them.

const std = @import("std");

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");
const Layouts = @import("../Layouts.zig");

/// What the page remembers between drawings: the list to add a layout from.
var add_choice: Kit.Dropdown = .{ .selected = 0 };
const add_names = blk: {
    var names: [Layouts.known.len + 1][]const u8 = undefined;
    names[0] = "Add a keyboard";
    for (Layouts.known, 1..) |k, i| names[i] = k.name;
    break :blk names;
};

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern fn time(t: ?*i64) i64;
extern fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
extern fn strftime(out: [*]u8, max: usize, format: [*:0]const u8, tm: *const Tm) usize;

pub fn draw(app: *Settings, kit: *Kit) void {
    switch (app.sub) {
        .date_time => dateTime(kit),
        .language => language(app, kit),
        else => {
            app.linkCard(kit, .date_time, .clock, "Time zone, the time now");
            app.linkCard(kit, .language, .translate, "Display language, keyboard layout");
        },
    }
}

fn dateTime(kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    var now = time(null);
    var tm: Tm = undefined;
    _ = localtime_r(&now, &tm);
    var clock_buffer: [64]u8 = undefined;
    const clock_len = strftime(&clock_buffer, clock_buffer.len, "%H:%M", &tm);
    var date_buffer: [128]u8 = undefined;
    const date_len = strftime(&date_buffer, date_buffer.len, "%A, %B %e, %Y", &tm);
    {
        u.open(.{ .width = .grow, .padding = .trbl(4, 4, 16, 4), .direction = .top_to_bottom });
        defer u.close();
        kit.label(clock_buffer[0..clock_len], .title_large, p.text_primary);
        kit.label(date_buffer[0..date_len], .body, p.text_secondary);
    }
    var zone_buffer: [256]u8 = undefined;
    Settings.infoCard(kit, "time/zone", .globe, "Time zone", timeZone(&zone_buffer));
    Settings.infoCard(kit, "time/abbr", .clock, "Time zone abbreviation", if (tm.zone) |z| std.mem.span(z) else "");
}

/// The zone /etc/localtime is a link to, as tz names it: "Europe/Budapest".
fn timeZone(buffer: []u8) []const u8 {
    const n = std.c.readlink("/etc/localtime", buffer.ptr, buffer.len);
    if (n <= 0) return "UTC";
    const target = buffer[0..@intCast(n)];
    const marker = "zoneinfo/";
    return if (std.mem.indexOf(u8, target, marker)) |at| target[at + marker.len ..] else target;
}

fn language(app: *Settings, kit: *Kit) void {
    const lang = if (std.c.getenv("LANG")) |l| std.mem.span(l) else "C";
    Settings.infoCard(kit, "lang/locale", .translate, "Display language and region", lang);
    keyboards(app, kit);
}

/// The keyboard layouts to switch between with Windows key + Space: the
/// system's alone until another is added, then each with the way to take
/// it off.
fn keyboards(app: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    kit.section("Keyboards");
    var buffer: [4096]u8 = undefined;
    const system = keyboardLayout(&buffer);
    var list_buffer: [128]u8 = undefined;
    const list = if (app.store.layouts_len > 0) app.store.layouts() else blk: {
        const n = @min(system.len, list_buffer.len);
        @memcpy(list_buffer[0..n], system[0..n]);
        break :blk list_buffer[0..n];
    };
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |_| count += 1;
    var entries = std.mem.tokenizeScalar(u8, list, ',');
    var i: usize = 0;
    var removed: ?usize = null;
    while (entries.next()) |entry| : (i += 1) {
        var short_buffer: [8]u8 = undefined;
        kit.cardBegin(kit.print("kb/{d}", .{i}), .{ .icon = .keyboard, .title = Layouts.name(entry), .description = Layouts.short(entry, &short_buffer) });
        if (count > 1) if (kit.button(kit.print("kb/{d}/remove", .{i}), "Remove", .{})) {
            removed = i;
        };
        _ = kit.cardEnd(false);
    }
    if (removed) |gone| {
        // The rest, as they were.
        var out: [128]u8 = undefined;
        var n: usize = 0;
        var again = std.mem.tokenizeScalar(u8, list, ',');
        var j: usize = 0;
        while (again.next()) |entry| : (j += 1) {
            if (j == gone) continue;
            if (n > 0 and n < out.len) {
                out[n] = ',';
                n += 1;
            }
            const m = @min(entry.len, out.len - n);
            @memcpy(out[n..][0..m], entry[0..m]);
            n += m;
        }
        app.store.setLayouts(out[0..n]);
        app.save();
    }
    u.open(.{ .width = .grow, .padding = .trbl(8, 0, 0, 0), .gap = 12, .align_y = .center });
    defer u.close();
    if (kit.dropdown("kb/add", &add_choice, &add_names, .fixed(260))) {
        if (add_choice.selected > 0) {
            const code = Layouts.known[add_choice.selected - 1].code;
            var out: [128]u8 = undefined;
            const joined = std.fmt.bufPrint(&out, "{s},{s}", .{ list, code }) catch list;
            if (std.mem.indexOf(u8, list, code) == null) {
                app.store.setLayouts(joined);
                app.save();
            }
            add_choice.selected = 0;
        }
    }
    kit.label("Windows key + Space switches between them.", .caption, p.text_secondary);
}

/// The console's layout, which a session is started with.
fn keyboardLayout(buffer: []u8) []const u8 {
    const fd = std.c.open("/etc/vconsole.conf", .{});
    if (fd < 0) return "us";
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buffer.ptr, buffer.len);
    if (n <= 0) return "us";
    var lines = std.mem.splitScalar(u8, buffer[0..@intCast(n)], '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "KEYMAP=")) {
        return std.mem.trim(u8, line["KEYMAP=".len..], "\"");
    };
    return "us";
}
