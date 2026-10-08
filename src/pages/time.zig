// SPDX-License-Identifier: BSD-2-Clause

//! Time & language: the date and the time, the time zone, the language
//! and the keyboard layout - as the system has them.

const std = @import("std");

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");

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
        .language => language(kit),
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

fn language(kit: *Kit) void {
    const lang = if (std.c.getenv("LANG")) |l| std.mem.span(l) else "C";
    Settings.infoCard(kit, "lang/locale", .translate, "Display language and region", lang);
    var buffer: [4096]u8 = undefined;
    Settings.infoCard(kit, "lang/keyboard", .keyboard, "Keyboard layout", keyboardLayout(&buffer));
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
