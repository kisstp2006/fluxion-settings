// SPDX-License-Identifier: BSD-2-Clause

//! Settings: the desktop's own, laid out as Windows 11's - who is signed in
//! and a search at the top of a navigation pane, the areas under it, and
//! the page of the one chosen beside it: a title that says where it is, and
//! cards, each a setting and its control, or the way to a page of more.
//!
//! ```
//! ┌──────────────────┬─────────────────────────────────────────┐
//! │ (K) Kiss Tibor   │ System › Display                        │
//! │ [Find a setting] │ ┌─────────────────────────────────────┐ │
//! │ ▣ System         │ │ ☀ Brightness          ───●────────  │ │
//! │ ▢ Bluetooth      │ ├─────────────────────────────────────┤ │
//! │ ▢ Network        │ │ ☾ Night light                 [on]  │ │
//! │ ▢ Personalization│ └─────────────────────────────────────┘ │
//! └──────────────────┴─────────────────────────────────────────┘
//! ```
//!
//! What is chosen is kept in `settings.ini`, where the shell takes it from
//! at once; what is the system's - the volume, the brightness, the power
//! mode, Bluetooth - is set where it is kept, over the session's sound
//! server and the system bus.

const std = @import("std");
const xkb = @import("xkbcommon");
const dbus = @import("fluxion_dbus");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Window = @import("Window.zig");
const Store = @import("Store.zig");
const Portal = @import("Portal.zig");
const Motion = @import("Motion.zig");
const Pictures = @import("Pictures.zig");
const apps_mod = @import("apps.zig");
const Displays = @import("Displays.zig");

const system_page = @import("pages/system.zig");
const display_page = @import("pages/display.zig");
const personalization = @import("pages/personalization.zig");
const apps_page = @import("pages/apps.zig");
const devices = @import("pages/devices.zig");
const network = @import("pages/network.zig");
const accounts = @import("pages/accounts.zig");
const time_page = @import("pages/time.zig");

const Settings = @This();

const log = std.log.scoped(.settings);

pub const Page = enum { system, devices, network, personalization, apps, accounts, time };

/// A page inside an area: Display inside System.
pub const Sub = enum {
    none,
    display,
    advanced_display,
    sound,
    notifications,
    power,
    clipboard,
    about,
    background,
    colors,
    themes,
    taskbar,
    desktop_icons,
    installed,
    shortcuts,
    info,
    date_time,
    language,
};

const nav_width = 320;
/// Folded to its icons: as wide as one of them, with the pane's margins.
const nav_compact = 64;
/// Narrower than this, the pane folds to its icons by itself, as Windows'
/// does, and opens again as the window widens.
const narrow_width = 900;

gpa: std.mem.Allocator,
io: std.Io,
window: Window = undefined,
store: Store,
page: Page = .system,
sub: Sub = .none,
/// The system bus: the brightness, the power mode, Bluetooth, the network.
system: ?*dbus.Connection = null,
/// The file chooser, on the session bus: a picture, a folder.
portal: Portal = undefined,
portal_watched: bool = false,
pictures: Pictures = undefined,
/// A page coming in, as WinUI brings one: another area up from below into
/// place; a page inside one grown into place from a little smaller, as if
/// gone into; and back out, settled from a little larger.
page_motion: Motion = .{ .duration = 300, .ease = .popup },
page_transition: enum { entrance, drill_in, drill_out } = .entrance,
/// The shortcut whose keys are being chosen: the next keys pressed.
recording: ?Store.Shortcut = null,
/// The navigation pane open, or folded to its icons - by its button, or the
/// window being narrow - and the motion of it folding or opening.
nav_open: bool = true,
nav_was_narrow: bool = false,
nav_motion: Motion = .{ .duration = 250, .ease = .point_to_point },
nav_from: f32 = nav_width,
nav_to: f32 = nav_width,
/// The pill by the chosen area, moving to another: from where it was to
/// where it goes, in the window's pixels, as WinUI's does - stretched
/// toward the new area first, its far end then drawn in after it.
pill_page: ?Page = null,
pill_from: f32 = 0,
pill_to: f32 = 0,
pill_motion: Motion = .{ .duration = 450, .ease = .decelerate },
/// What Enter opens in the search: the first finding listed.
search_first: ?struct { page: Page, sub: Sub } = null,
/// The screens, where the compositor tells of them.
displays: ?*Displays = null,
display_state: display_page.State = .{},
/// A watch on the file the choices are kept in: the shell writes to it too.
store_watch: ?std.c.fd_t = null,
/// Rings a moment after a new look is chosen: this window takes it then,
/// after the compositor has taken its picture of the screens to cross
/// over from. See `rethemeSoon`.
retheme_timer: ?std.c.fd_t = null,
apps: ?apps_mod.Apps = null,

/// What the pages show, read when they open.
system_state: system_page.State = .{},
devices_state: devices.State = .{},
network_state: network.State = .{},
personalization_state: personalization.State = .{},

pub fn init(self: *Settings, gpa: std.mem.Allocator, io: std.Io) !void {
    const store = Store.load(io);
    self.* = .{ .gpa = gpa, .io = io, .store = store };
    self.portal = .{ .gpa = gpa };
    try self.window.init(gpa, io, "Settings", "org.fluxion.Settings", modeOf(store.mode), widgets.Accent.from(widgets.argb(store.accent)), lookOf(store.look), .{
        .context = self,
        .draw = draw,
        .key = key,
        .button = pointerButton,
    });
    self.pictures.init(gpa, io);
    self.window.addWatch(.{ .fd = self.pictures.wake[0], .context = self, .ready = picturesReady });
    if (self.window.output_manager) |manager| {
        self.displays = Displays.init(gpa, manager) catch null;
        if (self.displays) |d| d.changed = .{ .context = self, .call = displaysChanged };
    }
    self.store_watch = Store.watch(io);
    if (self.store_watch) |fd| self.window.addWatch(.{ .fd = fd, .context = self, .ready = storeChanged });
    const timer = std.os.linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (std.os.linux.errno(timer) == .SUCCESS) {
        self.retheme_timer = @intCast(timer);
        self.window.addWatch(.{ .fd = @intCast(timer), .context = self, .ready = rethemeRang });
    }
    if (dbus.Connection.open(gpa, .system)) |bus| {
        self.system = bus;
        self.window.addWatch(.{ .fd = bus.fd, .context = self, .ready = systemReady, .wants_write = systemWantsWrite });
    } else |err| log.warn("no system bus: {t}", .{err});
}

pub fn deinit(self: *Settings) void {
    if (self.displays) |d| d.deinit();
    self.pictures.deinit();
    if (self.store_watch) |fd| _ = std.c.close(fd);
    if (self.retheme_timer) |fd| _ = std.c.close(fd);
    if (self.apps) |*a| a.deinit();
    if (self.system) |bus| bus.close();
    self.portal.deinit();
    self.window.deinit();
}

/// The look as the widgets draw it.
pub fn lookOf(look: Store.Look) widgets.theme.Look {
    return .{
        .style = switch (look.style) {
            .win11 => .win11,
            .win10 => .win10,
        },
        .rounded = look.rounded_corners,
        .transparency = look.transparency,
    };
}

fn modeOf(mode: Store.Mode) widgets.Mode {
    return switch (mode) {
        .light => .light,
        .dark => .dark,
    };
}

/// Open at `link`: a page or one inside it, as the shell asks - "display",
/// "sound", "wifi", "bluetooth", "background", "about".
pub fn openAt(self: *Settings, link: []const u8) void {
    // As a link too: "settings:display", as Windows' "ms-settings:display".
    const name = if (std.mem.lastIndexOfScalar(u8, link, ':')) |colon| link[colon + 1 ..] else link;
    const Target = struct { name: []const u8, page: Page, sub: Sub };
    const targets = [_]Target{
        .{ .name = "display", .page = .system, .sub = .display },
        .{ .name = "sound", .page = .system, .sub = .sound },
        .{ .name = "notifications", .page = .system, .sub = .notifications },
        .{ .name = "power", .page = .system, .sub = .power },
        .{ .name = "clipboard", .page = .system, .sub = .clipboard },
        .{ .name = "about", .page = .system, .sub = .about },
        .{ .name = "shortcuts", .page = .system, .sub = .shortcuts },
        .{ .name = "bluetooth", .page = .devices, .sub = .none },
        .{ .name = "network", .page = .network, .sub = .none },
        .{ .name = "wifi", .page = .network, .sub = .none },
        .{ .name = "background", .page = .personalization, .sub = .background },
        .{ .name = "colors", .page = .personalization, .sub = .colors },
        .{ .name = "themes", .page = .personalization, .sub = .themes },
        .{ .name = "taskbar", .page = .personalization, .sub = .taskbar },
        .{ .name = "desktopicons", .page = .personalization, .sub = .desktop_icons },
        .{ .name = "apps", .page = .apps, .sub = .installed },
        .{ .name = "accounts", .page = .accounts, .sub = .none },
        .{ .name = "datetime", .page = .time, .sub = .date_time },
        .{ .name = "region", .page = .time, .sub = .language },
    };
    for (targets) |t| if (std.mem.eql(u8, t.name, name)) return self.go(t.page, t.sub);
}

fn displaysChanged(context: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    display_page.displaysChanged(self);
    self.window.redraw();
}

/// Go to a page, or one inside it - where it is already, nowhere: the page
/// does not come in again.
pub fn go(self: *Settings, page: Page, sub: Sub) void {
    if (self.page == page and self.sub == sub) return;
    // Another area, or into a page of this one, or back out of it.
    const deeper = page == self.page and depth(sub) > depth(self.sub);
    self.page_transition = if (page != self.page) .entrance else if (deeper) .drill_in else .drill_out;
    self.page_motion = switch (self.page_transition) {
        // WinUI's: up 140 pixels over 300 ms; grown from 94 % over 783;
        // settled from 106 % over 333.
        .entrance => .{ .duration = 300, .ease = .popup },
        .drill_in => .{ .duration = 783, .ease = .popup },
        .drill_out => .{ .duration = 333, .ease = .decelerate },
    };
    self.page = page;
    self.sub = sub;
    self.window.layout.scrollTo("content/scroll", 0, 0);
    self.page_motion.begin();
    self.opened();
    self.window.redraw();
}

/// How far in a page is: an area's own, a page of it, a page of that.
fn depth(sub: Sub) u8 {
    return switch (sub) {
        .none => 0,
        .advanced_display => 2,
        else => 1,
    };
}

/// A page opened: what it shows read again.
fn opened(self: *Settings) void {
    switch (self.page) {
        .system => if (self.sub == .display or self.sub == .advanced_display) display_page.opened(self) else system_page.opened(self),
        .devices => devices.opened(self),
        .network => network.opened(self),
        .personalization => if (self.sub == .background) self.pictures.start(),
        .apps => if (self.apps == null) {
            self.apps = apps_mod.load(self.gpa, self.io) catch null;
        },
        else => {},
    }
}

/// A choice made: kept, and so taken by the desktop.
pub fn save(self: *Settings) void {
    self.store.save(self.io);
}

/// The look changed here: this window takes it too.
pub fn retheme(self: *Settings) void {
    self.window.setTheme(modeOf(self.store.mode), widgets.Accent.from(widgets.argb(self.store.accent)), lookOf(self.store.look));
}

/// Take the look chosen a moment from now: the compositor crosses the
/// screens over from a picture of them as they were, which must not have
/// this window in the new look already. Without a timer, at once.
pub fn rethemeSoon(self: *Settings) void {
    const fd = self.retheme_timer orelse return self.retheme();
    const spec: std.os.linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 120 * std.time.ns_per_ms },
    };
    if (std.os.linux.errno(std.os.linux.timerfd_settime(fd, .{}, &spec, null)) != .SUCCESS) self.retheme();
}

fn rethemeRang(context: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    var expirations: u64 = 0;
    _ = std.c.read(self.retheme_timer.?, std.mem.asBytes(&expirations), 8);
    self.retheme();
}

/// The file changed - written here, or by the shell from quick settings:
/// what it says now is shown.
fn storeChanged(context: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    if (!Store.changed(self.store_watch.?)) return;
    const before = self.store;
    self.store = Store.load(self.io);
    if (before.mode != self.store.mode or before.accent != self.store.accent or !std.meta.eql(before.look, self.store.look)) self.rethemeSoon();
    self.window.redraw();
}

fn picturesReady(context: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    if (self.pictures.collect(&self.window.icons)) self.window.redraw();
}

/// The file chooser, asked for a picture or a folder; `chose` hears of it.
pub fn choose(self: *Settings, want: Portal.Want, title: []const u8) void {
    const bus = self.portal.connect() orelse return;
    if (!self.portal_watched) {
        self.portal_watched = true;
        self.window.addWatch(.{ .fd = bus.fd, .context = self, .ready = portalReady, .wants_write = portalWantsWrite });
    }
    self.portal.choose(want, title, .{ .context = self, .call = chose });
}

fn chose(context: *anyopaque, want: Portal.Want, path: []const u8) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    switch (want) {
        .picture => {
            self.store.setWallpaper(path);
            self.store.background = .picture;
        },
        .folder => {
            self.store.setSlideshowFolder(path);
            self.store.background = .slideshow;
        },
    }
    self.save();
    self.window.redraw();
}

fn portalReady(context: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    const bus = self.portal.bus orelse return;
    bus.dispatch() catch {
        log.warn("the session bus went away", .{});
    };
}

fn portalWantsWrite(context: *anyopaque) bool {
    const self: *Settings = @ptrCast(@alignCast(context));
    return if (self.portal.bus) |bus| bus.wantsWrite() else false;
}

fn systemReady(context: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    const bus = self.system orelse return;
    bus.dispatch() catch {
        log.warn("the system bus went away", .{});
        bus.close();
        self.system = null;
    };
}

fn systemWantsWrite(context: *anyopaque) bool {
    const self: *Settings = @ptrCast(@alignCast(context));
    return if (self.system) |bus| bus.wantsWrite() else false;
}

fn key(context: *anyopaque, window: *Window, sym: xkb.Keysym) bool {
    const self: *Settings = @ptrCast(@alignCast(context));
    if (self.recording) |which| {
        self.recordKey(window, which, sym);
        return true;
    }
    if (display_page.key(self, sym)) return true;
    // Enter in the search: what it found.
    const K = xkb.Keysym;
    if ((@intFromEnum(sym) == K.Return or @intFromEnum(sym) == K.KP_Enter) and window.layout.isFocused("search")) {
        if (self.search_first) |f| self.openFound(f.page, f.sub);
        return true;
    }
    if (@intFromEnum(sym) == K.Escape and window.layout.isFocused("search") and (window.layout.textValueOf("search") orelse @as([]const u8, "")).len > 0) {
        window.layout.setTextValue("search", "");
        return true;
    }
    // Back, out of a page inside an area: Alt+Left, or Escape.
    if (@intFromEnum(sym) == xkb.Keysym.Escape and self.sub != .none) {
        self.go(self.page, if (self.sub == .advanced_display) .display else .none);
        return true;
    }
    return false;
}

/// A mouse's button pressed while a shortcut is being chosen: its middle or
/// a side button, with whatever modifiers are held - a mouse's side button
/// alone is a fine key for the microphone.
fn pointerButton(context: *anyopaque, window: *Window, code: u32) bool {
    const self: *Settings = @ptrCast(@alignCast(context));
    const which = self.recording orelse return false;
    const name: []const u8 = switch (code) {
        0x112 => "MouseMiddle",
        0x113, 0x116 => "Mouse4",
        0x114, 0x115 => "Mouse5",
        0x117 => "Mouse6",
        else => return false,
    };
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    if (window.modifierHeld("Mod4")) w.writeAll("Super+") catch return false;
    if (window.modifierHeld("Control")) w.writeAll("Ctrl+") catch return false;
    if (window.modifierHeld("Mod1")) w.writeAll("Alt+") catch return false;
    if (window.modifierHeld("Shift")) w.writeAll("Shift+") catch return false;
    w.writeAll(name) catch return false;
    self.store.shortcuts.getPtr(which).set(w.buffered());
    self.recording = null;
    self.save();
    return true;
}

/// A shortcut as a person reads it: "Mouse4" as the back button.
pub fn comboText(buffer: []u8, combo: []const u8) []const u8 {
    const names = [_]struct { []const u8, []const u8 }{
        .{ "MouseMiddle", "Middle mouse button" },
        .{ "Mouse4", "Mouse back button" },
        .{ "Mouse5", "Mouse forward button" },
        .{ "Mouse6", "Mouse button 6" },
    };
    for (names) |n| if (std.mem.endsWith(u8, combo, n[0])) {
        const prefix = combo[0 .. combo.len - n[0].len];
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ prefix, n[1] }) catch combo;
    };
    return combo;
}

/// A key pressed while a shortcut is being chosen: with its modifiers, the
/// shortcut's keys.
fn recordKey(self: *Settings, window: *Window, which: Store.Shortcut, sym: xkb.Keysym) void {
    const code = @intFromEnum(sym);
    const K = xkb.Keysym;
    switch (code) {
        // A modifier alone: the key it goes with is still to come.
        K.Shift_L, K.Shift_R, K.Control_L, K.Control_R, K.Alt_L, K.Alt_R, K.Super_L, K.Super_R, K.Meta_L, K.Meta_R, K.ISO_Level3_Shift => return,
        K.Escape => {
            self.recording = null;
            return;
        },
        K.BackSpace => {
            self.store.shortcuts.getPtr(which).set("");
            self.recording = null;
            self.save();
            return;
        },
        else => {},
    }
    const ctrl = window.modifierHeld("Control");
    const alt = window.modifierHeld("Mod1");
    const super = window.modifierHeld("Mod4");
    const shift = window.modifierHeld("Shift");
    // Without Ctrl, Alt or the Windows key it would take a key from typing.
    if (!ctrl and !alt and !super) return;
    var name_buffer: [64]u8 = undefined;
    const n = xkb.Keysym.getName(xkb.Keysym.toLower(sym), &name_buffer, name_buffer.len);
    if (n <= 0) return;
    var name = name_buffer[0..@intCast(n)];
    if (name.len == 1) name[0] = std.ascii.toUpper(name[0]);
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    if (super) w.writeAll("Super+") catch return;
    if (ctrl) w.writeAll("Ctrl+") catch return;
    if (alt) w.writeAll("Alt+") catch return;
    if (shift) w.writeAll("Shift+") catch return;
    w.writeAll(name) catch return;
    self.store.shortcuts.getPtr(which).set(w.buffered());
    self.recording = null;
    self.save();
}

// -------------------------------------------------------------------------
// The window
// -------------------------------------------------------------------------

const Area = struct { page: Page, icon: widgets.icons.Name, title: []const u8 };
const areas = [_]Area{
    .{ .page = .system, .icon = .laptop, .title = "System" },
    .{ .page = .devices, .icon = .bluetooth, .title = "Bluetooth & devices" },
    .{ .page = .network, .icon = .wifi_1, .title = "Network & internet" },
    .{ .page = .personalization, .icon = .paint_brush, .title = "Personalization" },
    .{ .page = .apps, .icon = .apps, .title = "Apps" },
    .{ .page = .accounts, .icon = .person, .title = "Accounts" },
    .{ .page = .time, .icon = .globe, .title = "Time & language" },
};

pub fn areaTitle(page: Page) []const u8 {
    for (areas) |a| if (a.page == page) return a.title;
    return "";
}

fn draw(context: *anyopaque, window: *Window, kit: *Kit) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    const u = kit.ui;
    const p = &kit.theme.palette;
    // Narrowed past the line, the pane folds; widened, it opens again.
    const narrow = window.width < narrow_width;
    if (narrow != self.nav_was_narrow) {
        self.nav_was_narrow = narrow;
        self.setNavOpen(!narrow);
    }
    // Mica's tint over the blur behind; with none - Windows 10's look, or
    // transparency off - the window's own solid colour.
    // Windows 10's acrylic pane: the window clear, the pane tinted over the
    // blur behind it, the page solid.
    u.open(.{ .width = .grow, .height = .grow, .background_color = if (window.mica) widgets.material.tint(kit.theme.mode) else if (window.acrylic) .transparent else p.solid_base });
    defer u.close();
    // Over everything: the question whether to keep the screens' new mode.
    defer display_page.keepDialog(self, kit);
    self.navigation(kit);
    if (window.acrylic) {
        window.setGlassStrip(@intFromFloat(@round(self.navWidth())));
        u.open(.{ .width = .grow, .height = .grow, .background_color = p.solid_base });
    }
    defer if (window.acrylic) u.close();
    kit.layerBegin("content", .{});
    defer u.close();
    // The title stays where it is; the cards scroll under it.
    {
        u.open(.{ .width = .grow, .padding = .trbl(24, 36, 0, 36) });
        defer u.close();
        self.header(kit);
    }
    u.open(.{ .id = "content/scroll", .width = .grow, .height = .grow, .direction = .top_to_bottom, .clip = .scrollY });
    defer u.close();
    const t = self.page_motion.progress();
    if (self.page_motion.running()) self.window.redraw();
    const shown: struct { y: f32, scale: f32, opacity: f32 } = switch (self.page_transition) {
        .entrance => .{ .y = Motion.mix(140, 0, t), .scale = 1, .opacity = self.page_motion.fade(0, 100) },
        .drill_in => .{ .y = 0, .scale = Motion.mix(0.94, 1, t), .opacity = Motion.curve(.decelerate, @min(1, self.page_motion.fade(0, 333))) },
        .drill_out => .{ .y = 0, .scale = Motion.mix(1.06, 1, t), .opacity = self.page_motion.fade(0, 333) },
    };
    u.open(.{
        .width = .grow,
        .direction = .top_to_bottom,
        .padding = .trbl(0, 36, 36, 36),
        .gap = 4,
        .translate = .{ .x = 0, .y = shown.y },
        .scale = if (shown.scale != 1) .by(shown.scale) else null,
        .opacity = shown.opacity,
    });
    defer u.close();
    switch (self.page) {
        .system => system_page.draw(self, kit),
        .devices => devices.draw(self, kit),
        .network => network.draw(self, kit),
        .personalization => personalization.draw(self, kit),
        .apps => apps_page.draw(self, kit),
        .accounts => accounts.draw(self, kit),
        .time => time_page.draw(self, kit),
    }
}

/// The page's title, as a breadcrumb: the area, and the page inside it -
/// the area's name a way back to it.
fn header(self: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .gap = 12, .align_y = .center, .padding = .trbl(0, 0, 20, 0) });
    defer u.close();
    const area = areaTitle(self.page);
    if (self.sub == .none) {
        kit.label(area, .title, p.text_primary);
        return;
    }
    const back_id = "header/area";
    const hovered = u.isPointerOver(back_id);
    u.open(.{ .id = back_id });
    kit.label(area, .title, if (hovered) p.text_primary else p.text_secondary);
    if (u.justReleased()) self.go(self.page, .none);
    u.close();
    kit.icon(.chevron_right, 16, p.text_secondary, .regular);
    // Inside Display: Display a way back too.
    if (self.sub == .advanced_display) {
        const display_id = "header/display";
        const over = u.isPointerOver(display_id);
        u.open(.{ .id = display_id });
        kit.label(subTitle(.display), .title, if (over) p.text_primary else p.text_secondary);
        if (u.justReleased()) self.go(self.page, .display);
        u.close();
        kit.icon(.chevron_right, 16, p.text_secondary, .regular);
    }
    kit.label(subTitle(self.sub), .title, p.text_primary);
}

pub fn subTitle(sub: Sub) []const u8 {
    return switch (sub) {
        .none => "",
        .display => "Display",
        .advanced_display => "Advanced display",
        .sound => "Sound",
        .notifications => "Notifications",
        .power => "Power",
        .clipboard => "Clipboard",
        .about => "About",
        .shortcuts => "Keyboard shortcuts",
        .background => "Background",
        .colors => "Colors",
        .themes => "Themes",
        .taskbar => "Taskbar",
        .desktop_icons => "Desktop icons",
        .installed => "Installed apps",
        .info => "Your info",
        .date_time => "Date & time",
        .language => "Language & region",
    };
}

/// Open the pane to its names, or fold it to its icons - as it is now,
/// from wherever it is on its way.
fn setNavOpen(self: *Settings, open: bool) void {
    if (open == self.nav_open) return;
    self.nav_from = self.navWidth();
    self.nav_to = if (open) nav_width else nav_compact;
    self.nav_open = open;
    self.nav_motion.begin();
    self.window.redraw();
}

fn px(v: f32) u16 {
    return @intFromFloat(@round(@max(0, v)));
}

/// How wide the pane is drawn now.
fn navWidth(self: *Settings) f32 {
    if (self.nav_motion.running()) self.window.redraw();
    return Motion.mix(self.nav_from, self.nav_to, self.nav_motion.progress());
}

fn navigation(self: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const width = self.navWidth();
    // How open it is: what fades the names in and out.
    const open = std.math.clamp((width - nav_compact) / (nav_width - nav_compact), 0, 1);
    u.open(.{
        .id = "nav",
        .width = .fixed(width),
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .all(8),
        .gap = 4,
        .clip = .both,
        // Windows 10's acrylic: its tint over the blur.
        .background_color = if (self.window.acrylic) (if (kit.theme.mode == .dark) widgets.argb(0x991F1F1F) else widgets.argb(0x99E6E6E6)) else .transparent,
    });
    defer u.close();
    // The button that folds it and opens it.
    {
        const id = "nav/toggle";
        const hovered = u.isPointerOver(id);
        u.open(.{
            .id = id,
            .width = .fixed(48),
            .height = .fixed(36),
            .align_x = .center,
            .align_y = .center,
            .corner_radius = .all(4),
            .background_color = if (u.isElementPressed(id)) p.subtle_tertiary else if (hovered) p.subtle_secondary else .transparent,
        });
        kit.icon(.navigation, 16, p.text_primary, .regular);
        if (u.justReleased()) self.setNavOpen(!self.nav_open);
        u.close();
    }
    // Who is signed in: a click goes to their info. Folded, the picture.
    {
        const id = "nav/person";
        const picture = Motion.mix(32, 64, open);
        u.open(.{
            .id = id,
            .width = .grow,
            .gap = 16,
            .align_y = .center,
            .padding = .trbl(px(Motion.mix(4, 12, open)), px(Motion.mix(0, 8, open)), px(Motion.mix(4, 16, open)), 8),
            .corner_radius = .all(4),
            .background_color = if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
        });
        defer u.close();
        const person = accounts.person();
        {
            u.open(.{ .width = .fixed(picture), .height = .fixed(picture), .corner_radius = .all(picture / 2), .background_color = p.accent, .align_x = .center, .align_y = .center });
            defer u.close();
            kit.label(person.initials(), if (open > 0.5) .subtitle else .body_strong, p.text_on_accent);
        }
        if (open > 0.02) {
            u.open(.{ .direction = .top_to_bottom, .opacity = open });
            var strong = kit.style(.body_strong, p.text_primary);
            strong.wrap = .none;
            u.text(person.display(), strong);
            var small = kit.style(.caption, p.text_secondary);
            small.wrap = .none;
            u.text("Local account", small);
            u.close();
        }
        if (u.justReleased()) self.go(.accounts, .info);
    }
    // The search: folded, its icon, which opens the pane to it.
    if (open > 0.5) {
        u.open(.{ .width = .grow, .padding = .trbl(0, 4, 8, 4), .opacity = std.math.clamp(open * 2 - 1, 0, 1) });
        defer u.close();
        kit.textField("search", .{ .placeholder = "Find a setting", .width = .grow, .icon = .search });
    } else {
        if (self.navRow(kit, "nav/search", .search, "Find a setting", false, open)) {
            self.setNavOpen(true);
            u.setFocus("search");
        }
    }
    for (areas) |a| {
        if (self.navRow(kit, kit.print("nav/{t}", .{a.page}), a.icon, a.title, self.page == a.page, open)) self.go(a.page, .none);
    }
    self.pill(kit);
    // What a search finds, under the box, the areas left where they are.
    const query = u.textValueOf("search") orelse "";
    if (query.len > 0 and open > 0.5) self.searchResults(kit, query);
}

/// An area in the pane: its icon, and its name while the pane is open
/// enough to show it. True on the frame it is clicked.
fn navRow(self: *Settings, kit: *Kit, id: []const u8, icon: widgets.icons.Name, title: []const u8, selected: bool, open: f32) bool {
    _ = self;
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = u.isPointerOver(id);
    const pressed = u.isElementPressed(id);
    // Windows 10 marks the area it is in with the bar alone.
    const ten = kit.theme.look.style == .win10;
    const fill = if (selected and !ten)
        (if (hovered) p.subtle_tertiary else p.subtle_secondary)
    else if (pressed) p.subtle_tertiary else if (hovered) p.subtle_secondary else ui.Color.transparent;
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(kit.theme.metrics.nav_item_height),
        .padding = .trbl(0, 8, 0, 16),
        .gap = 16,
        .align_y = .center,
        .background_color = fill,
        .corner_radius = .all(kit.theme.metrics.control_radius),
    });
    kit.icon(icon, 16, p.text_primary, if (selected) .filled else .regular);
    if (open > 0.02) {
        u.open(.{ .opacity = open });
        var style = kit.style(.body, p.text_primary);
        style.wrap = .none;
        u.text(title, style);
        u.close();
    }
    const clicked = u.justReleased();
    u.close();
    return clicked;
}

/// The pill by the chosen area. Moved to another, it stretches toward it -
/// its leading end first - and its trailing end follows, so for a moment
/// it spans both, as WinUI's navigation does.
fn pill(self: *Settings, kit: *Kit) void {
    const p = &kit.theme.palette;
    // Windows 11's short pill, or Windows 10's taller square bar.
    const pill_h: f32 = kit.theme.metrics.pill_height;
    const row = self.window.boxOf(kit.print("nav/{t}", .{self.page})) orelse return;
    const target = row.y + (row.height - pill_h) / 2;
    if (self.pill_page != self.page) {
        // Somewhere to come from: where it is shown now.
        self.pill_from = if (self.pill_page == null) target else self.pillShown(pill_h)[0];
        self.pill_to = target;
        self.pill_page = self.page;
        self.pill_motion.begin();
    } else {
        // The rows moved - the pane folding: it goes with them.
        self.pill_to = target;
        if (!self.pill_motion.running()) self.pill_from = target;
    }
    if (self.pill_motion.running()) self.window.redraw();
    const top, const bottom = self.pillShown(pill_h);
    kit.ui.empty(.{
        .width = .fixed(kit.theme.metrics.pill_width),
        .height = .fixed(@max(pill_h, bottom - top)),
        .corner_radius = .all(1.5),
        .background_color = p.accent,
        .floating = .{ .attach = .root, .offset = .{ .x = row.x, .y = top }, .z_index = 5 },
        .passthrough = true,
    });
}

/// The pill's top and bottom as drawn now.
fn pillShown(self: *const Settings, pill_h: f32) [2]f32 {
    const t = self.pill_motion.elapsed();
    const lead = Motion.curve(.decelerate, std.math.clamp(t / 0.55, 0, 1));
    const trail = Motion.curve(.decelerate, std.math.clamp((t - 0.3) / 0.7, 0, 1));
    const lead_y = Motion.mix(self.pill_from, self.pill_to, lead);
    const trail_y = Motion.mix(self.pill_from, self.pill_to, trail);
    if (self.pill_to >= self.pill_from) return .{ trail_y, lead_y + pill_h };
    return .{ lead_y, trail_y + pill_h };
}

/// What a search finds: the pages whose names or words match, the way to
/// each.
fn searchResults(self: *Settings, kit: *Kit, query: []const u8) void {
    const Hit = struct { page: Page, sub: Sub, title: []const u8, words: []const u8 };
    const hits = [_]Hit{
        .{ .page = .system, .sub = .display, .title = "Display", .words = "brightness night light screen monitor resolution scale orientation rotate dpi size kijelző fényerő skálázás felbontás" },
        .{ .page = .system, .sub = .advanced_display, .title = "Advanced display", .words = "refresh rate hz display information monitor frissítési" },
        .{ .page = .system, .sub = .sound, .title = "Sound", .words = "volume speakers output audio mute hang hangerő" },
        .{ .page = .system, .sub = .notifications, .title = "Notifications", .words = "do not disturb toasts alerts értesítések" },
        .{ .page = .system, .sub = .power, .title = "Power", .words = "screen off sleep battery energy mode performance energia" },
        .{ .page = .system, .sub = .clipboard, .title = "Clipboard", .words = "clipboard history copy paste cut clear emoji vágólap másolás beillesztés" },
        .{ .page = .system, .sub = .shortcuts, .title = "Keyboard shortcuts", .words = "keyboard shortcuts hotkeys keys microphone mute gyorsbillentyű billentyűparancs" },
        .{ .page = .system, .sub = .about, .title = "About", .words = "device name processor memory ram version kernel specifications névjegy" },
        .{ .page = .devices, .sub = .none, .title = "Bluetooth & devices", .words = "bluetooth mouse keyboard headphones paired" },
        .{ .page = .network, .sub = .none, .title = "Network & internet", .words = "wifi wi-fi ethernet connection network hálózat" },
        .{ .page = .personalization, .sub = .background, .title = "Background", .words = "wallpaper picture desktop háttér háttérkép" },
        .{ .page = .personalization, .sub = .colors, .title = "Colors", .words = "dark light mode theme accent colour color téma szín" },
        .{ .page = .personalization, .sub = .themes, .title = "Themes", .words = "theme style windows 10 windows 11 look rounded corners square floating docked transparency téma stílus kinézet lekerekítés sarkok lebegő átlátszóság" },
        .{ .page = .personalization, .sub = .desktop_icons, .title = "Desktop icons", .words = "desktop icons recycle bin trash this pc computer network asztal ikonok lomtár" },
        .{ .page = .personalization, .sub = .taskbar, .title = "Taskbar", .words = "taskbar alignment left center search task view badges flashing show desktop tálca" },
        .{ .page = .apps, .sub = .installed, .title = "Installed apps", .words = "apps programs applications alkalmazások" },
        .{ .page = .accounts, .sub = .info, .title = "Your info", .words = "account user name picture fiók" },
        .{ .page = .time, .sub = .date_time, .title = "Date & time", .words = "clock time zone date dátum idő" },
        .{ .page = .time, .sub = .language, .title = "Language & region", .words = "language keyboard layout region locale nyelv billentyűzet" },
    };
    const p = &kit.theme.palette;
    const u = kit.ui;
    u.open(.{
        .id = "search/suggestions",
        .width = .fixed(nav_width - 24),
        .direction = .top_to_bottom,
        .padding = .all(4),
        .gap = 2,
        .background_color = p.flyout,
        .corner_radius = .all(8),
        .border = .{ .color = p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.flyout),
        .floating = .{ .attach = .id, .to = "search/frame", .anchor = .below, .offset = .{ .x = 0, .y = 4 }, .z_index = 50 },
    });
    defer u.close();
    var any = false;
    self.search_first = null;
    for (hits, 0..) |h, i| {
        const matches = std.ascii.indexOfIgnoreCase(h.title, query) != null or std.ascii.indexOfIgnoreCase(h.words, query) != null;
        if (!matches) continue;
        any = true;
        if (self.search_first == null) self.search_first = .{ .page = h.page, .sub = h.sub };
        if (kit.navItem(kit.print("hit/{d}", .{i}), iconOf(h.page), h.title, false)) self.openFound(h.page, h.sub);
    }
    if (!any) {
        u.open(.{ .padding = .all(12) });
        kit.label("No results", .body, p.text_secondary);
        u.close();
    }
}

fn iconOf(page: Page) widgets.icons.Name {
    for (areas) |a| if (a.page == page) return a.icon;
    return .settings;
}

/// A search's finding opened: the box emptied, the page shown.
fn openFound(self: *Settings, page: Page, sub: Sub) void {
    self.window.layout.setTextValue("search", "");
    self.search_first = null;
    self.go(page, sub);
}

// -------------------------------------------------------------------------
// Shared pieces of pages
// -------------------------------------------------------------------------

/// A card that is the way to a page inside the area.
pub fn linkCard(self: *Settings, kit: *Kit, sub: Sub, icon: widgets.icons.Name, description: []const u8) void {
    const id = kit.print("link/{t}", .{sub});
    kit.cardBegin(id, .{ .icon = icon, .title = subTitle(sub), .description = description, .clickable = true });
    if (kit.cardEnd(true)) self.go(self.page, sub);
}

/// A card with nothing to change: a name and its value.
pub fn infoCard(kit: *Kit, id: []const u8, icon: ?widgets.icons.Name, title: []const u8, value: []const u8) void {
    kit.cardBegin(id, .{ .icon = icon, .title = title });
    var style = kit.style(.body, kit.theme.palette.text_secondary);
    style.wrap = .none;
    kit.ui.text(value, style);
    _ = kit.cardEnd(false);
}
