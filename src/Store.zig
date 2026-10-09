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
//! style=win11
//! rounded_corners=true
//! window_corners=true
//! floating=true
//! transparency=true
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
/// Personalization ▸ Themes: Windows 11's look or 10's, and its corners,
/// panels and materials.
look: Look = .{},
wallpaper_buffer: [512]u8 = undefined,
wallpaper_len: usize = 0,
night_light: bool = false,
night_light_kelvin: u32 = 4500,
/// Night light by itself: never, sunset to sunrise, or between two times
/// - minutes after midnight.
night_schedule: NightSchedule = .off,
night_on: u16 = 21 * 60,
night_off: u16 = 7 * 60,
do_not_disturb: bool = false,
/// Storage Sense: off until turned on; how often, how long the Recycle Bin
/// keeps things; and "Run now", as a stamp that changes.
storage: Storage = .{},
/// How a mouse and a touchpad move and scroll.
mouse: Pointer = .{ .tap_to_click = false },
touchpad: Pointer = .{},
/// The keyboard layouts to switch between: "hu,us".
layouts_buffer: [128]u8 = undefined,
layouts_len: usize = 0,
/// A picture, or a slideshow of a folder's pictures.
background: Background = .picture,
slideshow_buffer: [512]u8 = undefined,
slideshow_len: usize = 0,
slideshow_minutes: u32 = 30,
slideshow_shuffle: bool = false,
/// Do not disturb by itself: the hours, an app filling the screen; and a
/// summary of what was missed.
focus: FocusRules = .{},
/// Nought for never.
screen_off_minutes: u32 = 5,
taskbar: Taskbar = .{},
/// The system's icons on the desktop - Windows' Desktop Icon Settings.
desktop_icons: DesktopIcons = .{},
/// Keys chosen for what the shell does, from anywhere: "Super+Alt+K", or
/// nothing for none.
shortcuts: std.EnumArray(Shortcut, Combo) = .initFill(.{}),
mic_mute_sound: bool = true,
/// What is copied kept, for Super+V.
clipboard_history: bool = false,

pub const NightSchedule = enum { off, sunset, hours };

pub const Background = enum { picture, slideshow };

pub const Storage = struct {
    sense: bool = false,
    every_days: u32 = 7,
    trash_days: u32 = 30,
    run: u64 = 0,
};

pub const Pointer = struct {
    speed: i32 = 0,
    scroll: u32 = 100,
    natural_scrolling: bool = false,
    tap_to_click: bool = true,
    left_handed: bool = false,
    disable_while_typing: bool = true,
};

pub const FocusRules = struct {
    hours: bool = false,
    from: u16 = 22 * 60,
    to: u16 = 7 * 60,
    fullscreen: bool = true,
    summary: bool = true,
};

pub const Look = struct {
    style: Style = .win11,
    /// The interface's corners: controls, menus, flyouts, the start menu.
    rounded_corners: bool = true,
    /// Windows' own corners.
    window_corners: bool = true,
    /// Start, search and the flyouts float clear of the taskbar.
    floating: bool = true,
    /// Acrylic and Mica.
    transparency: bool = true,
    /// What title bars are made of, and the glass of apps that ask for it.
    title_bars: Material = .solid,
    windows: Material = .auto,

    pub const Material = enum { auto, solid, mica, acrylic };

    pub const Style = enum { win11, win10 };
};

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
    volume_mixer,
    clipboard,
    emoji,
    run,
    quick_settings,
    notification_center,
    project,

    pub fn default(self: Shortcut) []const u8 {
        return switch (self) {
            .mic_mute => "Super+Alt+K",
            .volume_mixer => "Super+Ctrl+V",
            .clipboard => "Super+V",
            .emoji => "Super+period",
            .run => "Super+R",
            .quick_settings => "Super+A",
            .notification_center => "Super+N",
            .project => "Super+P",
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
            .volume_mixer => "Volume mixer",
            .clipboard => "Clipboard history",
            .emoji => "Emoji and symbols",
            .run => "Run",
            .quick_settings => "Quick settings, or the Action Center",
            .notification_center => "Notifications and calendar",
            .project => "Project to a second screen",
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
    /// The clock with its seconds.
    seconds: bool = false,
    /// Aero Peek on the far corner.
    peek: bool = true,
    /// An app's windows under one button, labels hidden - always, when the
    /// taskbar is full, or never.
    combine: Combine = .always,

    pub const Combine = enum { always, when_full, never };

    pub const Alignment = enum { center, left };
    pub const Position = enum { bottom, top, left, right };
    pub const Search = enum { hide, icon };
};

pub fn wallpaper(self: *const Store) ?[]const u8 {
    return if (self.wallpaper_len > 0) self.wallpaper_buffer[0..self.wallpaper_len] else null;
}

pub fn layouts(self: *const Store) []const u8 {
    return self.layouts_buffer[0..self.layouts_len];
}

pub fn setLayouts(self: *Store, text: []const u8) void {
    self.layouts_len = @min(text.len, self.layouts_buffer.len);
    @memcpy(self.layouts_buffer[0..self.layouts_len], text[0..self.layouts_len]);
}

pub fn slideshowFolder(self: *const Store) ?[]const u8 {
    return if (self.slideshow_len > 0) self.slideshow_buffer[0..self.slideshow_len] else null;
}

pub fn setSlideshowFolder(self: *Store, folder: []const u8) void {
    self.slideshow_len = @min(folder.len, self.slideshow_buffer.len);
    @memcpy(self.slideshow_buffer[0..self.slideshow_len], folder[0..self.slideshow_len]);
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
        const l = &self.look;
        if (eql(u8, key, "style")) l.style = std.meta.stringToEnum(Look.Style, value) orelse l.style;
        if (eql(u8, key, "rounded_corners")) l.rounded_corners = !eql(u8, value, "false");
        if (eql(u8, key, "window_corners")) l.window_corners = !eql(u8, value, "false");
        if (eql(u8, key, "floating")) l.floating = !eql(u8, value, "false");
        if (eql(u8, key, "transparency")) l.transparency = !eql(u8, value, "false");
        if (eql(u8, key, "title_bar_material")) l.title_bars = std.meta.stringToEnum(Look.Material, value) orelse l.title_bars;
        if (eql(u8, key, "window_material")) l.windows = std.meta.stringToEnum(Look.Material, value) orelse l.windows;
    } else if (eql(u8, section, "desktop")) {
        if (eql(u8, key, "wallpaper")) self.setWallpaper(value);
        if (eql(u8, key, "background")) self.background = std.meta.stringToEnum(Background, value) orelse self.background;
        if (eql(u8, key, "slideshow_folder")) self.setSlideshowFolder(value);
        if (eql(u8, key, "slideshow_minutes")) self.slideshow_minutes = std.fmt.parseInt(u32, value, 10) catch self.slideshow_minutes;
        if (eql(u8, key, "slideshow_shuffle")) self.slideshow_shuffle = eql(u8, value, "true");
        const d = &self.desktop_icons;
        if (eql(u8, key, "icon_recycle_bin")) d.recycle_bin = !eql(u8, value, "false");
        if (eql(u8, key, "icon_computer")) d.computer = eql(u8, value, "true");
        if (eql(u8, key, "icon_home")) d.home = eql(u8, value, "true");
        if (eql(u8, key, "icon_network")) d.network = eql(u8, value, "true");
    } else if (eql(u8, section, "display")) {
        if (eql(u8, key, "night_light")) self.night_light = eql(u8, value, "true");
        if (eql(u8, key, "night_light_kelvin")) self.night_light_kelvin = std.fmt.parseInt(u32, value, 10) catch self.night_light_kelvin;
        if (eql(u8, key, "night_light_schedule")) self.night_schedule = std.meta.stringToEnum(NightSchedule, value) orelse self.night_schedule;
        if (eql(u8, key, "night_light_on")) self.night_on = parseTime(value) orelse self.night_on;
        if (eql(u8, key, "night_light_off")) self.night_off = parseTime(value) orelse self.night_off;
    } else if (eql(u8, section, "mouse") or eql(u8, section, "touchpad")) {
        const t = if (eql(u8, section, "mouse")) &self.mouse else &self.touchpad;
        if (eql(u8, key, "speed")) t.speed = std.fmt.parseInt(i32, value, 10) catch t.speed;
        if (eql(u8, key, "scroll")) t.scroll = std.fmt.parseInt(u32, value, 10) catch t.scroll;
        if (eql(u8, key, "natural_scrolling")) t.natural_scrolling = eql(u8, value, "true");
        if (eql(u8, key, "tap_to_click")) t.tap_to_click = eql(u8, value, "true");
        if (eql(u8, key, "left_handed")) t.left_handed = eql(u8, value, "true");
        if (eql(u8, key, "disable_while_typing")) t.disable_while_typing = eql(u8, value, "true");
    } else if (eql(u8, section, "storage")) {
        const g = &self.storage;
        if (eql(u8, key, "sense")) g.sense = eql(u8, value, "true");
        if (eql(u8, key, "every_days")) g.every_days = std.fmt.parseInt(u32, value, 10) catch g.every_days;
        if (eql(u8, key, "trash_days")) g.trash_days = std.fmt.parseInt(u32, value, 10) catch g.trash_days;
        if (eql(u8, key, "run")) g.run = std.fmt.parseInt(u64, value, 10) catch 0;
    } else if (eql(u8, section, "keyboard")) {
        if (eql(u8, key, "layouts")) self.setLayouts(value);
    } else if (eql(u8, section, "clipboard")) {
        if (eql(u8, key, "history")) self.clipboard_history = eql(u8, value, "true");
    } else if (eql(u8, section, "notifications")) {
        if (eql(u8, key, "do_not_disturb")) self.do_not_disturb = eql(u8, value, "true");
        const f = &self.focus;
        if (eql(u8, key, "focus_hours")) f.hours = eql(u8, value, "true");
        if (eql(u8, key, "focus_from")) f.from = parseTime(value) orelse f.from;
        if (eql(u8, key, "focus_to")) f.to = parseTime(value) orelse f.to;
        if (eql(u8, key, "focus_fullscreen")) f.fullscreen = !eql(u8, value, "false");
        if (eql(u8, key, "focus_summary")) f.summary = !eql(u8, value, "false");
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
        if (eql(u8, key, "seconds")) t.seconds = eql(u8, value, "true");
        if (eql(u8, key, "peek")) t.peek = !eql(u8, value, "false");
        if (eql(u8, key, "combine")) t.combine = std.meta.stringToEnum(Taskbar.Combine, value) orelse t.combine;
    }
}

/// "21:30" as minutes after midnight.
pub fn parseTime(text: []const u8) ?u16 {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const h = std.fmt.parseInt(u16, text[0..colon], 10) catch return null;
    const m = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    if (h > 23 or m > 59) return null;
    return h * 60 + m;
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
        \\style={t}
        \\rounded_corners={}
        \\window_corners={}
        \\floating={}
        \\transparency={}
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
        \\night_light_schedule={t}
        \\night_light_on={d:0>2}:{d:0>2}
        \\night_light_off={d:0>2}:{d:0>2}
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
        \\seconds={}
        \\
    , .{
        self.mode,                      self.accent & 0xFFFFFF,
        self.look.style,                self.look.rounded_corners,
        self.look.window_corners,       self.look.floating,
        self.look.transparency,         self.wallpaper() orelse "",
        self.desktop_icons.recycle_bin, self.desktop_icons.computer,
        self.desktop_icons.home,        self.desktop_icons.network,
        self.night_light,               self.night_light_kelvin,
        self.night_schedule,            self.night_on / 60,
        self.night_on % 60,             self.night_off / 60,
        self.night_off % 60,            self.do_not_disturb,
        self.screen_off_minutes,        self.taskbar.position,
        self.taskbar.alignment,         self.taskbar.search,
        self.taskbar.task_view,         self.taskbar.badges,
        self.taskbar.flashing,          self.taskbar.show_desktop_corner,
        self.taskbar.seconds,
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
    ours_writer.print("\n[clipboard]\nhistory={}\n", .{self.clipboard_history}) catch return;
    ours_writer.print("\n[desktop]\nbackground={t}\nslideshow_folder={s}\nslideshow_minutes={d}\nslideshow_shuffle={}\n", .{ self.background, self.slideshowFolder() orelse "", self.slideshow_minutes, self.slideshow_shuffle }) catch return;
    ours_writer.print("\n[appearance]\ntitle_bar_material={t}\nwindow_material={t}\n", .{ self.look.title_bars, self.look.windows }) catch return;
    ours_writer.print("\n[taskbar]\npeek={}\ncombine={t}\n", .{ self.taskbar.peek, self.taskbar.combine }) catch return;
    const g = self.storage;
    ours_writer.print("\n[storage]\nsense={}\nevery_days={d}\ntrash_days={d}\nrun={d}\n", .{ g.sense, g.every_days, g.trash_days, g.run }) catch return;
    if (self.layouts_len > 0) ours_writer.print("\n[keyboard]\nlayouts={s}\n", .{self.layouts()}) catch return;
    inline for (.{ .{ "mouse", self.mouse }, .{ "touchpad", self.touchpad } }) |pair| {
        const t = pair[1];
        ours_writer.print("\n[" ++ pair[0] ++ "]\nspeed={d}\nscroll={d}\nnatural_scrolling={}\ntap_to_click={}\nleft_handed={}\ndisable_while_typing={}\n", .{ t.speed, t.scroll, t.natural_scrolling, t.tap_to_click, t.left_handed, t.disable_while_typing }) catch return;
    }
    const f = self.focus;
    ours_writer.print("\n[notifications]\nfocus_hours={}\nfocus_from={d:0>2}:{d:0>2}\nfocus_to={d:0>2}:{d:0>2}\nfocus_fullscreen={}\nfocus_summary={}\n", .{ f.hours, f.from / 60, f.from % 60, f.to / 60, f.to % 60, f.fullscreen, f.summary }) catch return;
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
    store.look = .{ .style = .win10, .window_corners = false, .transparency = false };
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
    try std.testing.expectEqual(Look.Style.win10, back.look.style);
    try std.testing.expect(back.look.rounded_corners);
    try std.testing.expect(!back.look.window_corners);
    try std.testing.expect(back.look.floating);
    try std.testing.expect(!back.look.transparency);
}
