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
const Pictures = @import("Pictures.zig");
const apps_mod = @import("apps.zig");

const system_page = @import("pages/system.zig");
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
    sound,
    notifications,
    power,
    about,
    background,
    colors,
    taskbar,
    desktop_icons,
    installed,
    info,
    date_time,
    language,
};

const nav_width = 300;

gpa: std.mem.Allocator,
io: std.Io,
window: Window = undefined,
store: Store,
page: Page = .system,
sub: Sub = .none,
/// The system bus: the brightness, the power mode, Bluetooth, the network.
system: ?*dbus.Connection = null,
pictures: Pictures = undefined,
/// A watch on the file the choices are kept in: the shell writes to it too.
store_watch: ?std.c.fd_t = null,
apps: ?apps_mod.Apps = null,

/// What the pages show, read when they open.
system_state: system_page.State = .{},
devices_state: devices.State = .{},
network_state: network.State = .{},
personalization_state: personalization.State = .{},

pub fn init(self: *Settings, gpa: std.mem.Allocator, io: std.Io) !void {
    const store = Store.load(io);
    self.* = .{ .gpa = gpa, .io = io, .store = store };
    try self.window.init(gpa, io, "Settings", "org.fluxion.Settings", modeOf(store.mode), widgets.Accent.from(widgets.argb(store.accent)), .{
        .context = self,
        .draw = draw,
        .key = key,
    });
    self.pictures.init(gpa, io);
    self.window.addWatch(.{ .fd = self.pictures.wake[0], .context = self, .ready = picturesReady });
    self.store_watch = Store.watch(io);
    if (self.store_watch) |fd| self.window.addWatch(.{ .fd = fd, .context = self, .ready = storeChanged });
    if (dbus.Connection.open(gpa, .system)) |bus| {
        self.system = bus;
        self.window.addWatch(.{ .fd = bus.fd, .context = self, .ready = systemReady, .wants_write = systemWantsWrite });
    } else |err| log.warn("no system bus: {t}", .{err});
}

pub fn deinit(self: *Settings) void {
    self.pictures.deinit();
    if (self.store_watch) |fd| _ = std.c.close(fd);
    if (self.apps) |*a| a.deinit();
    if (self.system) |bus| bus.close();
    self.window.deinit();
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
        .{ .name = "about", .page = .system, .sub = .about },
        .{ .name = "bluetooth", .page = .devices, .sub = .none },
        .{ .name = "network", .page = .network, .sub = .none },
        .{ .name = "wifi", .page = .network, .sub = .none },
        .{ .name = "background", .page = .personalization, .sub = .background },
        .{ .name = "colors", .page = .personalization, .sub = .colors },
        .{ .name = "taskbar", .page = .personalization, .sub = .taskbar },
        .{ .name = "desktopicons", .page = .personalization, .sub = .desktop_icons },
        .{ .name = "apps", .page = .apps, .sub = .installed },
        .{ .name = "accounts", .page = .accounts, .sub = .none },
        .{ .name = "datetime", .page = .time, .sub = .date_time },
        .{ .name = "region", .page = .time, .sub = .language },
    };
    for (targets) |t| if (std.mem.eql(u8, t.name, name)) return self.go(t.page, t.sub);
}

/// Go to a page, or one inside it.
pub fn go(self: *Settings, page: Page, sub: Sub) void {
    self.page = page;
    self.sub = sub;
    self.window.layout.scrollTo("content/scroll", 0, 0);
    self.opened();
    self.window.redraw();
}

/// A page opened: what it shows read again.
fn opened(self: *Settings) void {
    switch (self.page) {
        .system => system_page.opened(self),
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
    self.window.setTheme(modeOf(self.store.mode), widgets.Accent.from(widgets.argb(self.store.accent)));
}

/// The file changed - written here, or by the shell from quick settings:
/// what it says now is shown.
fn storeChanged(context: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    if (!Store.changed(self.store_watch.?)) return;
    const before = self.store;
    self.store = Store.load(self.io);
    if (before.mode != self.store.mode or before.accent != self.store.accent) self.retheme();
    self.window.redraw();
}

fn picturesReady(context: *anyopaque) void {
    const self: *Settings = @ptrCast(@alignCast(context));
    if (self.pictures.collect(&self.window.icons)) self.window.redraw();
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

fn key(context: *anyopaque, _: *Window, sym: xkb.Keysym) bool {
    const self: *Settings = @ptrCast(@alignCast(context));
    // Back, out of a page inside an area: Alt+Left, or Escape.
    if (@intFromEnum(sym) == xkb.Keysym.Escape and self.sub != .none) {
        self.go(self.page, .none);
        return true;
    }
    return false;
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
    _ = window;
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .height = .grow, .background_color = widgets.material.tint(kit.theme.mode) });
    defer u.close();
    self.navigation(kit);
    kit.layerBegin("content", .{});
    defer u.close();
    u.open(.{ .id = "content/scroll", .width = .grow, .height = .grow, .direction = .top_to_bottom, .clip = .scrollY });
    defer u.close();
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .trbl(24, 36, 36, 36), .gap = 4 });
    defer u.close();
    self.header(kit);
    switch (self.page) {
        .system => system_page.draw(self, kit),
        .devices => devices.draw(self, kit),
        .network => network.draw(self, kit),
        .personalization => personalization.draw(self, kit),
        .apps => apps_page.draw(self, kit),
        .accounts => accounts.draw(self, kit),
        .time => time_page.draw(self, kit),
    }
    _ = p;
}

/// The page's title, as a breadcrumb: the area, and the page inside it -
/// the area's name a way back to it.
fn header(self: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .gap = 12, .align_y = .center, .padding = .trbl(0, 0, 16, 0) });
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
    kit.label(subTitle(self.sub), .title, p.text_primary);
}

pub fn subTitle(sub: Sub) []const u8 {
    return switch (sub) {
        .none => "",
        .display => "Display",
        .sound => "Sound",
        .notifications => "Notifications",
        .power => "Power",
        .about => "About",
        .background => "Background",
        .colors => "Colors",
        .taskbar => "Taskbar",
        .desktop_icons => "Desktop icons",
        .installed => "Installed apps",
        .info => "Your info",
        .date_time => "Date & time",
        .language => "Language & region",
    };
}

fn navigation(self: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .fixed(nav_width), .height = .grow, .direction = .top_to_bottom, .padding = .all(8), .gap = 4 });
    defer u.close();
    // Who is signed in: a click goes to their info.
    {
        const id = "nav/person";
        u.open(.{ .id = id, .width = .grow, .gap = 16, .align_y = .center, .padding = .trbl(12, 8, 16, 8), .corner_radius = .all(4), .background_color = if (u.isPointerOver(id)) p.subtle_secondary else .transparent });
        defer u.close();
        const person = accounts.person();
        {
            u.open(.{ .width = .fixed(60), .height = .fixed(60), .corner_radius = .all(30), .background_color = p.accent, .align_x = .center, .align_y = .center });
            defer u.close();
            kit.label(person.initials(), .subtitle, p.text_on_accent);
        }
        u.open(.{ .direction = .top_to_bottom });
        kit.label(person.display(), .body_strong, p.text_primary);
        kit.label("Local account", .caption, p.text_secondary);
        u.close();
        if (u.justReleased()) self.go(.accounts, .info);
    }
    {
        u.open(.{ .width = .grow, .padding = .trbl(0, 4, 8, 4) });
        defer u.close();
        kit.textField("search", .{ .placeholder = "Find a setting", .width = .grow, .icon = .search });
    }
    const query = u.textValueOf("search") orelse "";
    if (query.len > 0) return self.searchResults(kit, query);
    for (areas) |a| {
        if (kit.navItem(kit.print("nav/{t}", .{a.page}), a.icon, a.title, self.page == a.page)) self.go(a.page, .none);
    }
}

/// What a search finds: the pages whose names or words match, the way to
/// each.
fn searchResults(self: *Settings, kit: *Kit, query: []const u8) void {
    const Hit = struct { page: Page, sub: Sub, title: []const u8, words: []const u8 };
    const hits = [_]Hit{
        .{ .page = .system, .sub = .display, .title = "Display", .words = "brightness night light screen monitor resolution scale kijelző fényerő" },
        .{ .page = .system, .sub = .sound, .title = "Sound", .words = "volume speakers output audio mute hang hangerő" },
        .{ .page = .system, .sub = .notifications, .title = "Notifications", .words = "do not disturb toasts alerts értesítések" },
        .{ .page = .system, .sub = .power, .title = "Power", .words = "screen off sleep battery energy mode performance energia" },
        .{ .page = .system, .sub = .about, .title = "About", .words = "device name processor memory ram version kernel specifications névjegy" },
        .{ .page = .devices, .sub = .none, .title = "Bluetooth & devices", .words = "bluetooth mouse keyboard headphones paired" },
        .{ .page = .network, .sub = .none, .title = "Network & internet", .words = "wifi wi-fi ethernet connection network hálózat" },
        .{ .page = .personalization, .sub = .background, .title = "Background", .words = "wallpaper picture desktop háttér háttérkép" },
        .{ .page = .personalization, .sub = .colors, .title = "Colors", .words = "dark light mode theme accent colour color téma szín" },
        .{ .page = .personalization, .sub = .desktop_icons, .title = "Desktop icons", .words = "desktop icons recycle bin trash this pc computer network asztal ikonok lomtár" },
        .{ .page = .personalization, .sub = .taskbar, .title = "Taskbar", .words = "taskbar alignment left center search task view badges flashing show desktop tálca" },
        .{ .page = .apps, .sub = .installed, .title = "Installed apps", .words = "apps programs applications alkalmazások" },
        .{ .page = .accounts, .sub = .info, .title = "Your info", .words = "account user name picture fiók" },
        .{ .page = .time, .sub = .date_time, .title = "Date & time", .words = "clock time zone date dátum idő" },
        .{ .page = .time, .sub = .language, .title = "Language & region", .words = "language keyboard layout region locale nyelv billentyűzet" },
    };
    const p = &kit.theme.palette;
    var any = false;
    for (hits, 0..) |h, i| {
        const matches = std.ascii.indexOfIgnoreCase(h.title, query) != null or std.ascii.indexOfIgnoreCase(h.words, query) != null;
        if (!matches) continue;
        any = true;
        if (kit.navItem(kit.print("hit/{d}", .{i}), null, h.title, false)) {
            self.window.layout.setTextValue("search", "");
            self.go(h.page, h.sub);
        }
    }
    if (!any) {
        kit.ui.open(.{ .padding = .all(12) });
        kit.label("No results", .body, p.text_secondary);
        kit.ui.close();
    }
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
