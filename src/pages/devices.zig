// SPDX-License-Identifier: BSD-2-Clause

//! Bluetooth & devices: Bluetooth on or off, and the devices it knows -
//! as BlueZ has them on the system bus.

const std = @import("std");
const dbus = @import("fluxion_dbus");
const Value = dbus.Value;

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");
const Text = @import("system.zig").Text;

pub const State = struct {
    read: bool = false,
    /// Whether BlueZ answered at all.
    service: bool = false,
    adapter: Text(128) = .{},
    has_adapter: bool = false,
    powered: bool = false,
    devices: [16]Device = undefined,
    device_count: usize = 0,
};

const Device = struct {
    name: Text(96) = .{},
    icon: Text(48) = .{},
    paired: bool = false,
    connected: bool = false,
};

pub fn opened(app: *Settings) void {
    const bus = app.system orelse return;
    _ = bus.call(.{
        .destination = "org.bluez",
        .path = "/",
        .interface = "org.freedesktop.DBus.ObjectManager",
        .member = "GetManagedObjects",
    }, .{ .context = app, .call = gotObjects }) catch {};
}

fn gotObjects(context: *anyopaque, _: *dbus.Connection, message: *const dbus.Message) void {
    const app: *Settings = @ptrCast(@alignCast(context));
    const s = &app.devices_state;
    s.read = true;
    s.has_adapter = false;
    s.device_count = 0;
    s.service = !message.isError();
    if (message.isError()) return app.window.redraw();
    const objects = message.arg(0) orelse return;
    for (objects.asArray() orelse return) |entry| {
        if (entry != .dict_entry) continue;
        const path = entry.dict_entry[0].asString() orelse continue;
        const interfaces = entry.dict_entry[1];
        if (interfaces.lookup("org.bluez.Adapter1")) |adapter| {
            if (!s.has_adapter) {
                s.has_adapter = true;
                s.adapter.set(path);
                s.powered = flag(adapter, "Powered");
            }
        }
        if (interfaces.lookup("org.bluez.Device1")) |device| {
            if (s.device_count == s.devices.len) continue;
            if (!flag(device, "Paired")) continue;
            var d: Device = .{ .paired = true, .connected = flag(device, "Connected") };
            d.name.set(text(device, "Alias") orelse text(device, "Name") orelse "Device");
            d.icon.set(text(device, "Icon") orelse "");
            s.devices[s.device_count] = d;
            s.device_count += 1;
        }
    }
    app.window.redraw();
}

fn flag(dict: Value, name: []const u8) bool {
    return if (dict.lookup(name)) |v| v.asBool() orelse false else false;
}

fn text(dict: Value, name: []const u8) ?[]const u8 {
    return if (dict.lookup(name)) |v| v.asString() else null;
}

/// Bluetooth on or off, as BlueZ is told.
fn setPowered(app: *Settings) void {
    const s = &app.devices_state;
    const bus = app.system orelse return;
    const value: Value.Variant = .{ .signature = "b", .value = .{ .boolean = s.powered } };
    _ = bus.call(.{
        .destination = "org.bluez",
        .path = s.adapter.get(),
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .signature = "ssv",
        .args = &.{ .{ .string = "org.bluez.Adapter1" }, .{ .string = "Powered" }, .{ .variant = &value } },
    }, null) catch {};
}

pub fn draw(app: *Settings, kit: *Kit) void {
    const s = &app.devices_state;
    const u = kit.ui;
    const p = &kit.theme.palette;
    if (!s.read) return;
    if (!s.service) {
        kit.infoBar("bt/off", .informational, "Bluetooth is not running", "The Bluetooth service is stopped. To use Bluetooth, start it: sudo systemctl enable --now bluetooth");
        return;
    }
    if (!s.has_adapter) {
        kit.infoBar("bt/none", .informational, "No Bluetooth", "This device has no Bluetooth adapter.");
        return;
    }
    kit.cardBegin("bt/power", .{ .icon = .bluetooth, .title = "Bluetooth", .description = if (s.powered) "Discoverable as this device's name" else "Off" });
    if (kit.toggle("bt/power/toggle", &s.powered, .{})) setPowered(app);
    _ = kit.cardEnd(false);
    kit.section("Devices");
    if (s.device_count == 0) {
        kit.label("No paired devices. Pair one from quick settings on the taskbar.", .body, p.text_secondary);
        return;
    }
    for (s.devices[0..s.device_count], 0..) |*d, i| {
        const id = kit.print("bt/device/{d}", .{i});
        kit.cardBegin(id, .{ .icon = glyphOf(d.icon.get()), .title = d.name.get(), .description = if (d.connected) "Connected" else "Paired" });
        _ = kit.cardEnd(false);
    }
    _ = u;
}

fn glyphOf(icon: []const u8) widgets.icons.Name {
    if (std.mem.startsWith(u8, icon, "audio")) return .headphones;
    if (std.mem.startsWith(u8, icon, "input-keyboard")) return .keyboard;
    if (std.mem.startsWith(u8, icon, "phone")) return .phone;
    if (std.mem.startsWith(u8, icon, "computer")) return .laptop;
    return .bluetooth;
}
