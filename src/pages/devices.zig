// SPDX-License-Identifier: BSD-2-Clause

//! Bluetooth & devices: Bluetooth on or off, and the devices it knows -
//! as BlueZ has them on the system bus.

const std = @import("std");
const dbus = @import("fluxion_dbus");
const Value = dbus.Value;

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");
const Store = @import("../Store.zig");
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
    switch (app.sub) {
        .mouse => return mouse(app, kit),
        .touchpad => return touchpad(app, kit),
        else => {},
    }
    app.linkCard(kit, .mouse, .apps, "Primary button, pointer speed, scrolling");
    app.linkCard(kit, .touchpad, .laptop, "Taps, scrolling, speed");
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

// -------------------------------------------------------------------------
// Mouse and touchpad
// -------------------------------------------------------------------------

var primary_choice: Kit.Dropdown = .{};
var mouse_direction: Kit.Dropdown = .{};
var touchpad_direction: Kit.Dropdown = .{};

/// The mouse: which button is the main one, how fast the pointer goes, and
/// how far and which way the wheel scrolls.
fn mouse(app: *Settings, kit: *Kit) void {
    const m = &app.store.mouse;
    kit.cardBegin("mouse/primary", .{ .icon = .apps, .title = "Primary mouse button" });
    if (!primary_choice.open) primary_choice.selected = @intFromBool(m.left_handed);
    if (kit.dropdown("mouse/primary/list", &primary_choice, &.{ "Left", "Right" }, .fixed(140))) {
        m.left_handed = primary_choice.selected == 1;
        app.save();
    }
    _ = kit.cardEnd(false);
    speedCard(app, kit, "mouse/speed", "Mouse pointer speed", m);
    kit.section("Scrolling");
    scrollCard(app, kit, "mouse/scroll", "Scroll speed", "How far a notch of the wheel goes", m);
    directionCard(app, kit, "mouse/direction", &mouse_direction, m);
}

/// The touchpad: taps, speed, scrolling.
fn touchpad(app: *Settings, kit: *Kit) void {
    const t = &app.store.touchpad;
    speedCard(app, kit, "touchpad/speed", "Cursor speed", t);
    kit.section("Taps");
    kit.cardBegin("touchpad/tap", .{ .icon = .apps, .title = "Tap with a single finger to single-click" });
    if (kit.toggle("touchpad/tap/toggle", &t.tap_to_click, .{})) app.save();
    _ = kit.cardEnd(false);
    var on_while_typing = !t.disable_while_typing;
    kit.cardBegin("touchpad/typing", .{ .icon = .keyboard, .title = "Leave touchpad on while typing" });
    if (kit.toggle("touchpad/typing/toggle", &on_while_typing, .{})) {
        t.disable_while_typing = !on_while_typing;
        app.save();
    }
    _ = kit.cardEnd(false);
    kit.section("Scroll & zoom");
    scrollCard(app, kit, "touchpad/scroll", "Scroll speed", "How far a two-finger swipe goes", t);
    directionCard(app, kit, "touchpad/direction", &touchpad_direction, t);
}

fn speedCard(app: *Settings, kit: *Kit, id: []const u8, title: []const u8, pointer: *Store.Pointer) void {
    kit.cardBegin(id, .{ .icon = .arrow_right, .title = title });
    // Windows' 1 to 20, the middle libinput's own.
    var value: f32 = @as(f32, @floatFromInt(pointer.speed + 100)) / 200 * 19 + 1;
    if (kit.slider(kit.print("{s}/slider", .{id}), &value, .{ .min = 1, .max = 20, .step = 1, .width = .fixed(220) })) {
        pointer.speed = @intFromFloat(@round((value - 1) / 19 * 200 - 100));
        app.save();
    }
    _ = kit.cardEnd(false);
}

fn scrollCard(app: *Settings, kit: *Kit, id: []const u8, title: []const u8, description: []const u8, pointer: *Store.Pointer) void {
    kit.cardBegin(id, .{ .icon = .arrow_sort, .title = title, .description = description });
    var value: f32 = @floatFromInt(pointer.scroll);
    if (kit.slider(kit.print("{s}/slider", .{id}), &value, .{ .min = 25, .max = 300, .step = 25, .width = .fixed(220) })) {
        pointer.scroll = @intFromFloat(value);
        app.save();
    }
    _ = kit.cardEnd(false);
}

fn directionCard(app: *Settings, kit: *Kit, id: []const u8, choice: *Kit.Dropdown, pointer: *Store.Pointer) void {
    kit.cardBegin(id, .{ .icon = .arrow_sync, .title = "Scrolling direction" });
    if (!choice.open) choice.selected = @intFromBool(pointer.natural_scrolling);
    if (kit.dropdown(kit.print("{s}/list", .{id}), choice, &.{ "Down motion scrolls down", "Down motion scrolls up" }, .fixed(240))) {
        pointer.natural_scrolling = choice.selected == 1;
        app.save();
    }
    _ = kit.cardEnd(false);
}
