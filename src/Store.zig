// SPDX-License-Identifier: BSD-2-Clause

//! What is chosen in Settings, kept where the desktop reads it:
//! `$XDG_CONFIG_HOME/fluxion/settings.ini`. The shell watches the file and
//! takes a change as it is written - a new wallpaper, the dark mode, the
//! night light - so a choice here is seen at once.
//!
//! ```ini
//! [appearance]
//! mode=dark
//! accent=#1F6FCC
//!
//! [desktop]
//! wallpaper=/usr/share/backgrounds/f45/default/f45-01-day.png
//!
//! [display]
//! night_light=true
//! night_light_kelvin=4500
//!
//! [notifications]
//! do_not_disturb=false
//!
//! [power]
//! screen_off_minutes=5
//! ```
//!
//! Written whole, to a file beside it renamed over it: a reader never sees
//! half of it.
//!
//! The shell writes to it as well - night light and do not disturb are
//! switched from quick settings too - so it is watched here the same way,
//! on its folder, and read again when it changes.

const std = @import("std");
const linux = std.os.linux;

const Store = @This();

const log = std.log.scoped(.store);

pub const Mode = enum { light, dark };

mode: Mode = .dark,
/// 0xAARRGGBB.
accent: u32 = 0xFF1F6FCC,
wallpaper_buffer: [512]u8 = undefined,
wallpaper_len: usize = 0,
night_light: bool = false,
night_light_kelvin: u32 = 4500,
do_not_disturb: bool = false,
/// Nought for never.
screen_off_minutes: u32 = 5,

pub fn wallpaper(self: *const Store) ?[]const u8 {
    return if (self.wallpaper_len > 0) self.wallpaper_buffer[0..self.wallpaper_len] else null;
}

pub fn setWallpaper(self: *Store, file: []const u8) void {
    self.wallpaper_len = @min(file.len, self.wallpaper_buffer.len);
    @memcpy(self.wallpaper_buffer[0..self.wallpaper_len], file[0..self.wallpaper_len]);
}

/// The file's path, into `buffer`.
pub fn path(buffer: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |dir| return std.fmt.bufPrint(buffer, "{s}/fluxion/settings.ini", .{std.mem.span(dir)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.config/fluxion/settings.ini", .{std.mem.span(home)}) catch null;
}

/// A watch on the file's folder, for `changed`; null where there is none.
pub fn watch(io: std.Io) ?std.c.fd_t {
    var buffer: [512]u8 = undefined;
    const file = path(&buffer) orelse return null;
    const dir = std.fs.path.dirname(file) orelse return null;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var dir_z: [513]u8 = undefined;
    @memcpy(dir_z[0..dir.len], dir);
    dir_z[dir.len] = 0;
    const fd: isize = @bitCast(linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC));
    if (fd < 0) return null;
    const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.DELETE | linux.IN.MOVED_FROM;
    const added: isize = @bitCast(linux.inotify_add_watch(@intCast(fd), @ptrCast(&dir_z), mask));
    if (added < 0) {
        _ = std.c.close(@intCast(fd));
        return null;
    }
    return @intCast(fd);
}

/// Whether what the watch heard was of this file.
pub fn changed(fd: std.c.fd_t) bool {
    var ours = false;
    var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const n = std.c.read(fd, &buffer, buffer.len);
        if (n <= 0) break;
        var at: usize = 0;
        while (at + @sizeOf(linux.inotify_event) <= @as(usize, @intCast(n))) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[at]));
            if (event.getName()) |name| {
                if (std.mem.eql(u8, name, "settings.ini")) ours = true;
            }
            at += @sizeOf(linux.inotify_event) + event.len;
        }
    }
    return ours;
}

/// What is in the file, or the defaults for what is not.
pub fn load(io: std.Io) Store {
    var self: Store = .{};
    var buffer: [512]u8 = undefined;
    const file = path(&buffer) orelse return self;
    var text_buffer: [8192]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, file, &text_buffer) catch return self;
    self.parse(text);
    return self;
}

pub fn parse(self: *Store, text: []const u8) void {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            section = std.mem.trim(u8, line, "[]");
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        self.take(section, key, value);
    }
}

fn take(self: *Store, section: []const u8, key: []const u8, value: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, section, "appearance")) {
        if (eql(u8, key, "mode")) self.mode = std.meta.stringToEnum(Mode, value) orelse self.mode;
        if (eql(u8, key, "accent")) self.accent = parseColour(value) orelse self.accent;
    } else if (eql(u8, section, "desktop")) {
        if (eql(u8, key, "wallpaper")) self.setWallpaper(value);
    } else if (eql(u8, section, "display")) {
        if (eql(u8, key, "night_light")) self.night_light = eql(u8, value, "true");
        if (eql(u8, key, "night_light_kelvin")) self.night_light_kelvin = std.fmt.parseInt(u32, value, 10) catch self.night_light_kelvin;
    } else if (eql(u8, section, "notifications")) {
        if (eql(u8, key, "do_not_disturb")) self.do_not_disturb = eql(u8, value, "true");
    } else if (eql(u8, section, "power")) {
        if (eql(u8, key, "screen_off_minutes")) self.screen_off_minutes = std.fmt.parseInt(u32, value, 10) catch self.screen_off_minutes;
    }
}

/// "#RRGGBB" as 0xFFRRGGBB.
pub fn parseColour(text: []const u8) ?u32 {
    const hex = if (std.mem.startsWith(u8, text, "#")) text[1..] else text;
    if (hex.len != 6) return null;
    const rgb = std.fmt.parseInt(u32, hex, 16) catch return null;
    return 0xFF000000 | rgb;
}

/// The whole file, as written.
pub fn format(self: *const Store, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\[appearance]
        \\mode={t}
        \\accent=#{X:0>6}
        \\
        \\[desktop]
        \\wallpaper={s}
        \\
        \\[display]
        \\night_light={}
        \\night_light_kelvin={d}
        \\
        \\[notifications]
        \\do_not_disturb={}
        \\
        \\[power]
        \\screen_off_minutes={d}
        \\
    , .{ self.mode, self.accent & 0xFFFFFF, self.wallpaper() orelse "", self.night_light, self.night_light_kelvin, self.do_not_disturb, self.screen_off_minutes });
}

/// Write it, whole: to a file beside it, renamed over it.
pub fn save(self: *const Store, io: std.Io) void {
    var path_buffer: [512]u8 = undefined;
    const file = path(&path_buffer) orelse return;
    var text_buffer: [4096]u8 = undefined;
    const text = self.format(&text_buffer) catch return;
    const dir = std.fs.path.dirname(file) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var temp_buffer: [520]u8 = undefined;
    const temp = std.fmt.bufPrint(&temp_buffer, "{s}.new", .{file}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = text }) catch |err| {
        log.err("could not write {s}: {t}", .{ temp, err });
        return;
    };
    std.Io.Dir.rename(std.Io.Dir.cwd(), temp, std.Io.Dir.cwd(), file, io) catch |err| {
        log.err("could not put {s} in place: {t}", .{ file, err });
    };
}

test "what is written is read back" {
    var store: Store = .{ .mode = .light, .accent = 0xFF0E8A7D, .night_light = true, .screen_off_minutes = 10 };
    store.setWallpaper("/usr/share/backgrounds/lake.jpg");
    var buffer: [4096]u8 = undefined;
    const text = try store.format(&buffer);
    var back: Store = .{};
    back.parse(text);
    try std.testing.expectEqual(Mode.light, back.mode);
    try std.testing.expectEqual(@as(u32, 0xFF0E8A7D), back.accent);
    try std.testing.expectEqualStrings("/usr/share/backgrounds/lake.jpg", back.wallpaper().?);
    try std.testing.expect(back.night_light);
    try std.testing.expectEqual(@as(u32, 10), back.screen_off_minutes);
}
