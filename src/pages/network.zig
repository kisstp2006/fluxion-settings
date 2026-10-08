// SPDX-License-Identifier: BSD-2-Clause

//! Network & internet: whether there is a connection, which, and Wi-Fi on
//! or off - as NetworkManager has them on the system bus.

const std = @import("std");
const dbus = @import("fluxion_dbus");
const Value = dbus.Value;

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");
const Text = @import("system.zig").Text;

const nm = "org.freedesktop.NetworkManager";

pub const State = struct {
    read: bool = false,
    available: bool = false,
    /// NetworkManager's: 70 connected to the internet, 60 a site only, 50
    /// locally, lower not at all.
    state: u32 = 0,
    wifi: bool = false,
    name: Text(128) = .{},
    kind: Text(64) = .{},
};

pub fn opened(app: *Settings) void {
    const bus = app.system orelse return;
    _ = bus.call(.{
        .destination = nm,
        .path = "/org/freedesktop/NetworkManager",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "GetAll",
        .signature = "s",
        .args = &.{.{ .string = nm }},
    }, .{ .context = app, .call = gotManager }) catch {};
}

fn gotManager(context: *anyopaque, bus: *dbus.Connection, message: *const dbus.Message) void {
    const app: *Settings = @ptrCast(@alignCast(context));
    const s = &app.network_state;
    s.read = true;
    s.available = !message.isError();
    if (message.isError()) return app.window.redraw();
    const all = message.arg(0) orelse return;
    s.state = @intCast(if (all.lookup("State")) |v| v.asInt() orelse 0 else 0);
    s.wifi = if (all.lookup("WirelessEnabled")) |v| v.asBool() orelse false else false;
    s.name.set("");
    s.kind.set("");
    const primary = if (all.lookup("PrimaryConnection")) |v| v.asString() orelse "/" else "/";
    if (!std.mem.eql(u8, primary, "/")) {
        _ = bus.call(.{
            .destination = nm,
            .path = primary,
            .interface = "org.freedesktop.DBus.Properties",
            .member = "GetAll",
            .signature = "s",
            .args = &.{.{ .string = nm ++ ".Connection.Active" }},
        }, .{ .context = app, .call = gotPrimary }) catch {};
    }
    app.window.redraw();
}

fn gotPrimary(context: *anyopaque, _: *dbus.Connection, message: *const dbus.Message) void {
    const app: *Settings = @ptrCast(@alignCast(context));
    const s = &app.network_state;
    if (message.isError()) return;
    const all = message.arg(0) orelse return;
    if (all.lookup("Id")) |v| s.name.set(v.asString() orelse "");
    if (all.lookup("Type")) |v| s.kind.set(v.asString() orelse "");
    app.window.redraw();
}

fn setWifi(app: *Settings) void {
    const s = &app.network_state;
    const bus = app.system orelse return;
    const value: Value.Variant = .{ .signature = "b", .value = .{ .boolean = s.wifi } };
    _ = bus.call(.{
        .destination = nm,
        .path = "/org/freedesktop/NetworkManager",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .signature = "ssv",
        .args = &.{ .{ .string = nm }, .{ .string = "WirelessEnabled" }, .{ .variant = &value } },
    }, null) catch {};
}

pub fn draw(app: *Settings, kit: *Kit) void {
    const s = &app.network_state;
    const u = kit.ui;
    const p = &kit.theme.palette;
    if (!s.read) return;
    if (!s.available) {
        kit.infoBar("net/none", .caution, "No network manager", "NetworkManager is not running on this system.");
        return;
    }
    const wired = std.mem.indexOf(u8, s.kind.get(), "ethernet") != null;
    {
        u.open(.{ .width = .grow, .padding = .trbl(4, 4, 16, 4), .gap = 16, .align_y = .center });
        defer u.close();
        kit.icon(if (wired) .desktop_pulse else .wifi_1, 48, p.accent_text, .regular);
        u.open(.{ .direction = .top_to_bottom });
        defer u.close();
        kit.label(if (s.name.len > 0) s.name.get() else "Not connected", .subtitle, p.text_primary);
        kit.label(switch (s.state) {
            70 => "Connected, secured",
            60 => "Connected, no internet beyond this network",
            50 => "Connected locally",
            40 => "Connecting",
            else => "Not connected",
        }, .body, p.text_secondary);
    }
    kit.cardBegin("net/wifi", .{ .icon = .wifi_1, .title = "Wi-Fi", .description = "Connect to a network from quick settings on the taskbar" });
    if (kit.toggle("net/wifi/toggle", &s.wifi, .{})) setWifi(app);
    _ = kit.cardEnd(false);
    if (s.kind.len > 0) Settings.infoCard(kit, "net/kind", .network_check, "Connection", if (wired) "Ethernet" else if (std.mem.indexOf(u8, s.kind.get(), "wireless") != null) "Wi-Fi" else s.kind.get());
}
