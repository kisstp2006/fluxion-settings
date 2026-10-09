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
//!
//! [taskbar]
//! alignment=center
//! search=icon
//! task_view=true
//! badges=true
//! flashing=true
//! show_desktop_corner=true
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
taskbar: Taskbar = .{},
/// The system's icons on the desktop - Windows' Desktop Icon Settings.
desktop_icons: DesktopIcons = .{},
/// Keys chosen for what the shell does, from anywhere: "Super+Alt+K", or
/// nothing for none.
shortcuts: std.EnumArray(Shortcut, Combo) = .initFill(.{}),
mic_mute_sound: bool = true,

/// What a shortcut can do - as the shell knows them.
pub const Shortcut = enum {
    mic_mute,
    volume_up,
    volume_down,
    volume_mute,
    play_pause,
    next_track,
    previous_track,
    task_manager,
    files,
    settings,
    terminal,

    pub fn default(self: Shortcut) []const u8 {
        return switch (self) {
            .mic_mute => "Super+Alt+K",
            .task_manager => "Ctrl+Shift+Escape",
            .files => "Super+E",
            .settings => "Super+I",
            .terminal => "Ctrl+Alt+T",
            else => "",
        };
    }

    pub fn title(self: Shortcut) []const u8 {
        return switch (self) {
            .mic_mute => "Mute or unmute the microphone",
            .volume_up => "Volume up",
            .volume_down => "Volume down",
            .volume_mute => "Mute or unmute the sound",
            .play_pause => "Play or pause",
            .next_track => "Next track",
            .previous_track => "Previous track",
            .task_manager => "Task Manager",
            .files => "File Explorer",
            .settings => "Settings",
            .terminal => "Terminal",
        };
    }
};

pub const Combo = struct {
    text: [32]u8 = @splat(0),
    len: u8 = 0,
    given: bool = false,

    pub fn get(self: *const Combo, which: Shortcut) []const u8 {
        return if (self.given) self.text[0..self.len] else which.default();
    }

    pub fn set(self: *Combo, text: []const u8) void {
        self.len = @intCast(@min(text.len, self.text.len));
        @memcpy(self.text[0..self.len], text[0..self.len]);
        self.given = true;
    }
};

pub const DesktopIcons = struct {
    recycle_bin: bool = true,
    computer: bool = false,
    home: bool = false,
    network: bool = false,
};

/// Personalization ▸ Taskbar.
pub const Taskbar = struct {
    position: Position = .bottom,
    alignment: Alignment = .center,
    search: Search = .icon,
    task_view: bool = true,
    badges: bool = true,
    flashing: bool = true,
    show_desktop_corner: bool = true,

    pub const Alignment = enum { center, left };
    pub const Position = enum { bottom, top, left, right };
    pub const Search = enum { hide, icon };
};

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
        const d = &self.desktop_icons;
        if (eql(u8, key, "icon_recycle_bin")) d.recycle_bin = !eql(u8, value, "false");
        if (eql(u8, key, "icon_computer")) d.computer = eql(u8, value, "true");
        if (eql(u8, key, "icon_home")) d.home = eql(u8, value, "true");
        if (eql(u8, key, "icon_network")) d.network = eql(u8, value, "true");
    } else if (eql(u8, section, "display")) {
        if (eql(u8, key, "night_light")) self.night_light = eql(u8, value, "true");
        if (eql(u8, key, "night_light_kelvin")) self.night_light_kelvin = std.fmt.parseInt(u32, value, 10) catch self.night_light_kelvin;
    } else if (eql(u8, section, "notifications")) {
        if (eql(u8, key, "do_not_disturb")) self.do_not_disturb = eql(u8, value, "true");
    } else if (eql(u8, section, "power")) {
        if (eql(u8, key, "screen_off_minutes")) self.screen_off_minutes = std.fmt.parseInt(u32, value, 10) catch self.screen_off_minutes;
    } else if (eql(u8, section, "shortcuts")) {
        if (eql(u8, key, "mic_mute_sound")) {
            self.mic_mute_sound = !eql(u8, value, "false");
        } else if (std.meta.stringToEnum(Shortcut, key)) |which| self.shortcuts.getPtr(which).set(value);
    } else if (eql(u8, section, "taskbar")) {
        const t = &self.taskbar;
        if (eql(u8, key, "alignment")) t.alignment = std.meta.stringToEnum(Taskbar.Alignment, value) orelse t.alignment;
        if (eql(u8, key, "position")) t.position = std.meta.stringToEnum(Taskbar.Position, value) orelse t.position;
        if (eql(u8, key, "search")) t.search = std.meta.stringToEnum(Taskbar.Search, value) orelse t.search;
        if (eql(u8, key, "task_view")) t.task_view = !eql(u8, value, "false");
        if (eql(u8, key, "badges")) t.badges = !eql(u8, value, "false");
        if (eql(u8, key, "flashing")) t.flashing = !eql(u8, value, "false");
        if (eql(u8, key, "show_desktop_corner")) t.show_desktop_corner = !eql(u8, value, "false");
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
        \\icon_recycle_bin={}
        \\icon_computer={}
        \\icon_home={}
        \\icon_network={}
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
        \\[taskbar]
        \\position={t}
        \\alignment={t}
        \\search={t}
        \\task_view={}
        \\badges={}
        \\flashing={}
        \\show_desktop_corner={}
        \\
    , .{
        self.mode,                      self.accent & 0xFFFFFF,      self.wallpaper() orelse "",
        self.desktop_icons.recycle_bin, self.desktop_icons.computer, self.desktop_icons.home,
        self.desktop_icons.network,     self.night_light,            self.night_light_kelvin,
        self.do_not_disturb,            self.screen_off_minutes,     self.taskbar.position,
        self.taskbar.alignment,         self.taskbar.search,         self.taskbar.task_view,
        self.taskbar.badges,            self.taskbar.flashing,       self.taskbar.show_desktop_corner,
    });
}

/// Write it, whole: to a file beside it, renamed over it.
pub fn save(self: *const Store, io: std.Io) void {
    var path_buffer: [512]u8 = undefined;
    const file = path(&path_buffer) orelse return;
    var format_buffer: [4096]u8 = undefined;
    var ours_buffer: [6144]u8 = undefined;
    var ours_writer: std.Io.Writer = .fixed(&ours_buffer);
    ours_writer.writeAll(self.format(&format_buffer) catch return) catch return;
    // The shortcuts, after the rest: one line each.
    ours_writer.print("\n[shortcuts]\nmic_mute_sound={}\n", .{self.mic_mute_sound}) catch return;
    for (std.enums.values(Shortcut)) |which| ours_writer.print("{t}={s}\n", .{ which, self.shortcuts.get(which).get(which) }) catch return;
    const ours = ours_writer.buffered();
    // Written into the file as it is, a key at a time: what the shell keeps
    // there itself - the desktop's View, its Sort by - stays.
    var a_buffer: [16384]u8 = undefined;
    var b_buffer: [16384]u8 = undefined;
    var text: []const u8 = std.Io.Dir.cwd().readFile(io, file, &a_buffer) catch "";
    var into: *[16384]u8 = &b_buffer;
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, ours, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '[') {
            section = std.mem.trim(u8, line, "[]");
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        text = rewrite(into, text, section, line[0..eq], line[eq + 1 ..]) catch return;
        into = if (into == &b_buffer) &a_buffer else &b_buffer;
    }
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

/// Set `key` in `section` to `value` in the file, and nothing else: what a
/// screen was set to, under its own `[output NAME]`.
pub fn writeKey(io: std.Io, section: []const u8, key: []const u8, value: []const u8) void {
    var path_buffer: [512]u8 = undefined;
    const file = path(&path_buffer) orelse return;
    var read_buffer: [16384]u8 = undefined;
    var out_buffer: [16384]u8 = undefined;
    const text: []const u8 = std.Io.Dir.cwd().readFile(io, file, &read_buffer) catch "";
    const new = rewrite(&out_buffer, text, section, key, value) catch return;
    const dir = std.fs.path.dirname(file) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var temp_buffer: [520]u8 = undefined;
    const temp = std.fmt.bufPrint(&temp_buffer, "{s}.new", .{file}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = new }) catch |err| {
        log.err("could not write {s}: {t}", .{ temp, err });
        return;
    };
    std.Io.Dir.rename(std.Io.Dir.cwd(), temp, std.Io.Dir.cwd(), file, io) catch |err| {
        log.err("could not put {s} in place: {t}", .{ file, err });
    };
}

/// `text` with `key` in `section` set to `value`: changed where it is,
/// added at the end of its section, or the section added with it - the
/// rest as it was.
pub fn rewrite(buffer: []u8, text: []const u8, section: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    var current: []const u8 = "";
    var seen = false;
    var done = false;
    var blanks: usize = 0;
    const body = std.mem.trimEnd(u8, text, "\n");
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (if (body.len > 0) lines.next() else null) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const ours = std.mem.eql(u8, current, section);
        if (line.len > 0 and line[0] == '[') {
            if (ours and seen and !done) {
                try w.print("{s}={s}\n", .{ key, value });
                done = true;
            }
            try w.splatByteAll('\n', blanks);
            blanks = 0;
            current = std.mem.trim(u8, line, "[]");
            if (std.mem.eql(u8, current, section)) seen = true;
            try w.print("{s}\n", .{raw});
            continue;
        }
        if (ours and line.len == 0) {
            blanks += 1;
            continue;
        }
        try w.splatByteAll('\n', blanks);
        blanks = 0;
        if (ours and !done) if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " "), key)) {
                try w.print("{s}={s}\n", .{ key, value });
                done = true;
                continue;
            }
        };
        try w.print("{s}\n", .{raw});
    }
    if (!done) {
        if (seen and std.mem.eql(u8, current, section)) {
            try w.print("{s}={s}\n", .{ key, value });
        } else {
            if (w.end > 0) try w.writeByte('\n');
            try w.print("[{s}]\n{s}={s}\n", .{ section, key, value });
        }
    }
    try w.splatByteAll('\n', blanks);
    return w.buffered();
}

test "a key the shell keeps is kept when Settings writes its own" {
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    const shells = "[desktop]\nwallpaper=/a.jxl\nicon_size=large\n";
    const one = try rewrite(&a, shells, "desktop", "wallpaper", "/b.png");
    const two = try rewrite(&b, one, "appearance", "mode", "light");
    try std.testing.expectEqualStrings("[desktop]\nwallpaper=/b.png\nicon_size=large\n\n[appearance]\nmode=light\n", two);
}

test "what is written is read back" {
    var store: Store = .{ .mode = .light, .accent = 0xFF0E8A7D, .night_light = true, .screen_off_minutes = 10 };
    store.taskbar.alignment = .left;
    store.taskbar.badges = false;
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
    try std.testing.expectEqual(Taskbar.Alignment.left, back.taskbar.alignment);
    try std.testing.expect(!back.taskbar.badges);
    try std.testing.expect(back.taskbar.flashing);
}
