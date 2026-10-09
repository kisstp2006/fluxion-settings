// SPDX-License-Identifier: BSD-2-Clause

//! System: the display, the sound, the notifications, the power, and what
//! the machine is.

const std = @import("std");
const dbus = @import("fluxion_dbus");
const Value = dbus.Value;

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");
const Store = @import("../Store.zig");
const display_page = @import("display.zig");

const log = std.log.scoped(.system);

const backlights = "/sys/class/backlight";

pub const State = struct {
    // About, read once.
    about_read: bool = false,
    host: Text(64) = .{},
    cpu: Text(128) = .{},
    os: Text(128) = .{},
    kernel: Text(64) = .{},
    ram_gb: f32 = 0,

    // Sound.
    volume: f32 = 0,
    muted: bool = false,
    sound_known: bool = false,
    sinks: [8]Sink = undefined,
    sink_count: usize = 0,
    sink_choice: Kit.Dropdown = .{},
    // Input: the microphones, not the outputs' monitors.
    input_volume: f32 = 0,
    input_muted: bool = false,
    input_known: bool = false,
    sources: [8]Sink = undefined,
    source_count: usize = 0,
    source_choice: Kit.Dropdown = .{},

    // Display.
    backlight: ?Backlight = null,
    brightness: f32 = 0,
    night_strength: f32 = 50,

    // Power.
    screen_off: Kit.Dropdown = .{},
    profile: Text(32) = .{},
    profile_service: ?usize = null,
    profile_choice: Kit.Dropdown = .{},
};

pub fn Text(comptime n: usize) type {
    return struct {
        buffer: [n]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *@This(), text: []const u8) void {
            self.len = @min(text.len, n);
            @memcpy(self.buffer[0..self.len], text[0..self.len]);
        }

        pub fn get(self: *const @This()) []const u8 {
            return self.buffer[0..self.len];
        }
    };
}

const Sink = struct { name: Text(128) = .{}, description: Text(128) = .{} };

const Backlight = struct { name: Text(64) = .{}, max: u32, value: u32 };

/// The screen-off times on offer, in minutes; nought for never.
const screen_off_minutes = [_]u32{ 1, 2, 3, 5, 10, 15, 30, 0 };
const screen_off_names = [_][]const u8{ "1 minute", "2 minutes", "3 minutes", "5 minutes", "10 minutes", "15 minutes", "30 minutes", "Never" };

const profiles = [_][]const u8{ "power-saver", "balanced", "performance" };
const profile_names = [_][]const u8{ "Best power efficiency", "Balanced", "Best performance" };
const profile_services = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "org.freedesktop.UPower.PowerProfiles", .path = "/org/freedesktop/UPower/PowerProfiles" },
    .{ .name = "net.hadess.PowerProfiles", .path = "/net/hadess/PowerProfiles" },
};

pub fn opened(app: *Settings) void {
    const s = &app.system_state;
    switch (app.sub) {
        .about => readAbout(s),
        .sound => readSound(app),
        .display => {
            readBacklight(app);
            const k: f32 = @floatFromInt(app.store.night_light_kelvin);
            s.night_strength = std.math.clamp((6500 - k) / 35, 0, 100);
        },
        .power => {
            for (screen_off_minutes, 0..) |m, i| if (m == app.store.screen_off_minutes) {
                s.screen_off.selected = i;
            };
            readProfile(app, 0);
        },
        else => {},
    }
}

pub fn draw(app: *Settings, kit: *Kit) void {
    switch (app.sub) {
        .display => display_page.draw(app, kit),
        .advanced_display => display_page.advanced(app, kit),
        .sound => sound(app, kit),
        .notifications => notifications(app, kit),
        .power => power(app, kit),
        .about => about(app, kit),
        .shortcuts => shortcuts(app, kit),
        .clipboard => clipboard(app, kit),
        else => overview(app, kit),
    }
}

fn overview(app: *Settings, kit: *Kit) void {
    app.linkCard(kit, .display, .desktop, "Monitors, brightness, night light, scale");
    app.linkCard(kit, .sound, .speaker_2, "Volume levels, output, input, sound devices");
    app.linkCard(kit, .notifications, .alert, "Alerts from apps and system, do not disturb");
    app.linkCard(kit, .power, .power, "Screen off, power mode");
    app.linkCard(kit, .clipboard, .clipboard_paste, "Cut and copy history, clear");
    app.linkCard(kit, .shortcuts, .keyboard, "Keys for the microphone, the sound, and apps");
    app.linkCard(kit, .about, .info, "Device specifications, the system");
}

// -------------------------------------------------------------------------
// Clipboard
// -------------------------------------------------------------------------

fn clipboard(app: *Settings, kit: *Kit) void {
    kit.cardBegin("clipboard/history", .{
        .icon = .clipboard_paste,
        .title = "Clipboard history",
        .description = "Save multiple items to the clipboard to use later. Press Super+V to see your history and paste from it.",
    });
    if (kit.toggle("clipboard/history/toggle", &app.store.clipboard_history, .{})) app.save();
    _ = kit.cardEnd(false);
    kit.cardBegin("clipboard/clear", .{ .icon = .delete, .title = "Clear clipboard data", .description = "Clear everything except pinned items" });
    if (kit.button("clipboard/clear/button", "Clear", .{})) {
        // The shell keeps the history: told by a key it watches for.
        var buffer: [24]u8 = undefined;
        const stamp = std.fmt.bufPrint(&buffer, "{d}", .{@import("../Window.zig").nowMs()}) catch return;
        Store.writeKey(app.io, "clipboard", "cleared", stamp);
    }
    _ = kit.cardEnd(false);
    kit.cardBegin("clipboard/emoji", .{ .icon = .keyboard, .title = "Emoji and symbols", .description = "Press Super+. to put an emoji, a kaomoji or a symbol where you are typing" });
    _ = kit.cardEnd(false);
}

// -------------------------------------------------------------------------
// Display
// -------------------------------------------------------------------------

/// Brightness & color: the top of Display.
pub fn brightnessAndColor(app: *Settings, kit: *Kit) void {
    const s = &app.system_state;
    kit.section("Brightness & color");
    kit.cardBegin("brightness", .{ .icon = .brightness_high, .title = "Brightness", .description = if (s.backlight == null) "Change the brightness on the display itself" else "Adjust the brightness of the built-in display" });
    if (s.backlight != null) {
        if (kit.slider("brightness/slider", &s.brightness, .{ .min = 1, .max = 100, .step = 1, .width = .fixed(220) })) setBrightness(app);
    }
    _ = kit.cardEnd(false);

    kit.cardBegin("night", .{ .icon = .weather_moon, .title = "Night light", .description = "Use warmer colors to help block blue light" });
    if (kit.toggle("night/toggle", &app.store.night_light, .{})) app.save();
    _ = kit.cardEnd(false);
    kit.cardBegin("night-strength", .{ .title = "Strength" });
    if (kit.slider("night/strength", &s.night_strength, .{ .min = 0, .max = 100, .step = 1, .width = .fixed(220), .disabled = !app.store.night_light })) {
        app.store.night_light_kelvin = @intFromFloat(6500 - s.night_strength * 35);
        app.save();
    }
    _ = kit.cardEnd(false);
}

fn readBacklight(app: *Settings) void {
    const s = &app.system_state;
    s.backlight = null;
    var dir = std.Io.Dir.cwd().openDir(app.io, backlights, .{ .iterate = true }) catch return;
    defer dir.close(app.io);
    var it = dir.iterate();
    const entry = (it.next(app.io) catch return) orelse return;
    var b: Backlight = .{ .max = 0, .value = 0 };
    b.name.set(entry.name);
    b.max = readNumber(app, entry.name, "max_brightness") orelse return;
    b.value = readNumber(app, entry.name, "brightness") orelse return;
    if (b.max == 0) return;
    s.backlight = b;
    s.brightness = @as(f32, @floatFromInt(b.value)) * 100 / @as(f32, @floatFromInt(b.max));
}

fn readNumber(app: *Settings, name: []const u8, file: []const u8) ?u32 {
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}/{s}", .{ backlights, name, file }) catch return null;
    var buffer: [32]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(app.io, path, &buffer) catch return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch null;
}

/// As logind lets the person of the session do, with no password.
fn setBrightness(app: *Settings) void {
    const s = &app.system_state;
    const b = if (s.backlight) |*b| b else return;
    const bus = app.system orelse return;
    const value: u32 = @max(1, @as(u32, @intFromFloat(@round(s.brightness / 100 * @as(f32, @floatFromInt(b.max))))));
    if (value == b.value) return;
    b.value = value;
    _ = bus.call(.{
        .destination = "org.freedesktop.login1",
        .path = "/org/freedesktop/login1/session/auto",
        .interface = "org.freedesktop.login1.Session",
        .member = "SetBrightness",
        .signature = "ssu",
        .args = &.{ .{ .string = "backlight" }, .{ .string = b.name.get() }, .{ .uint32 = value } },
    }, null) catch {};
}

// -------------------------------------------------------------------------
// Sound
// -------------------------------------------------------------------------

fn sound(app: *Settings, kit: *Kit) void {
    const s = &app.system_state;
    kit.section("Output");
    if (!s.sound_known) {
        kit.infoBar("sound/none", .caution, "No sound server", "The volume is set through PipeWire or PulseAudio, and neither answered.");
        return;
    }
    if (s.sink_count > 0) {
        kit.cardBegin("sound/device", .{ .icon = .headphones, .title = "Choose where to play sound", .description = "Apps might have their own settings" });
        var names: [8][]const u8 = undefined;
        for (s.sinks[0..s.sink_count], 0..) |*sink, i| names[i] = sink.description.get();
        if (kit.dropdown("sound/device/list", &s.sink_choice, names[0..s.sink_count], .fixed(260))) {
            pactl(app, &.{ "pactl", "set-default-sink", s.sinks[s.sink_choice.selected].name.get() });
            readSound(app);
        }
        _ = kit.cardEnd(false);
    }
    kit.cardBegin("sound/volume", .{ .icon = if (s.muted) .speaker_mute else .speaker_2, .title = "Volume" });
    const before: u32 = @intFromFloat(@round(s.volume));
    if (kit.slider("sound/volume/slider", &s.volume, .{ .min = 0, .max = 100, .step = 1, .width = .fixed(220) })) {
        const now: u32 = @intFromFloat(@round(s.volume));
        if (now != before) {
            var buffer: [8]u8 = undefined;
            pactl(app, &.{ "pactl", "set-sink-volume", "@DEFAULT_SINK@", std.fmt.bufPrint(&buffer, "{d}%", .{now}) catch return });
        }
    }
    _ = kit.cardEnd(false);
    kit.cardBegin("sound/mute", .{ .icon = .speaker_mute, .title = "Mute" });
    if (kit.toggle("sound/mute/toggle", &s.muted, .{})) pactl(app, &.{ "pactl", "set-sink-mute", "@DEFAULT_SINK@", if (s.muted) "1" else "0" });
    _ = kit.cardEnd(false);

    kit.section("Input");
    if (s.source_count == 0 or !s.input_known) {
        kit.label("No microphone found.", .body, kit.theme.palette.text_secondary);
        return;
    }
    kit.cardBegin("mic/device", .{ .icon = .mic, .title = "Choose a device for speaking or recording", .description = "Apps might have their own settings" });
    var names: [8][]const u8 = undefined;
    for (s.sources[0..s.source_count], 0..) |*source, i| names[i] = source.description.get();
    if (kit.dropdown("mic/device/list", &s.source_choice, names[0..s.source_count], .fixed(260))) {
        pactl(app, &.{ "pactl", "set-default-source", s.sources[s.source_choice.selected].name.get() });
        readSound(app);
    }
    _ = kit.cardEnd(false);
    kit.cardBegin("mic/volume", .{ .icon = if (s.input_muted) .mic_off else .mic, .title = "Microphone volume" });
    const mic_before: u32 = @intFromFloat(@round(s.input_volume));
    if (kit.slider("mic/volume/slider", &s.input_volume, .{ .min = 0, .max = 100, .step = 1, .width = .fixed(220) })) {
        const now: u32 = @intFromFloat(@round(s.input_volume));
        if (now != mic_before) {
            var buffer: [8]u8 = undefined;
            pactl(app, &.{ "pactl", "set-source-volume", "@DEFAULT_SOURCE@", std.fmt.bufPrint(&buffer, "{d}%", .{now}) catch return });
        }
    }
    _ = kit.cardEnd(false);
    kit.cardBegin("mic/mute", .{ .icon = .mic_off, .title = "Mute the microphone", .description = "A shortcut can do it too: System > Keyboard shortcuts" });
    if (kit.toggle("mic/mute/toggle", &s.input_muted, .{})) pactl(app, &.{ "pactl", "set-source-mute", "@DEFAULT_SOURCE@", if (s.input_muted) "1" else "0" });
    _ = kit.cardEnd(false);
}

// -------------------------------------------------------------------------
// Keyboard shortcuts
// -------------------------------------------------------------------------

/// Keys for what the desktop does, from anywhere: a click on one's keys,
/// then the keys to use - Backspace for none, Escape to leave it.
fn shortcuts(app: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    kit.label("Select a shortcut, then press the keys to use - with Ctrl, Alt or the Windows key. Backspace removes it; Escape leaves it as it was.", .body, p.text_secondary);
    kit.section("Microphone");
    shortcutCard(app, kit, .mic_mute);
    kit.cardBegin("sc/mic-sound", .{ .icon = .speaker_2, .title = "Play a sound", .description = "As the microphone is muted, and heard again" });
    if (kit.toggle("sc/mic-sound/toggle", &app.store.mic_mute_sound, .{})) app.save();
    _ = kit.cardEnd(false);
    kit.section("Sound and media");
    inline for (.{ .volume_up, .volume_down, .volume_mute, .play_pause, .next_track, .previous_track }) |which| shortcutCard(app, kit, which);
    kit.section("Apps");
    inline for (.{ .task_manager, .files, .settings, .terminal }) |which| shortcutCard(app, kit, which);
    _ = u;
}

fn shortcutCard(app: *Settings, kit: *Kit, which: Store.Shortcut) void {
    const id = kit.print("sc/{t}", .{which});
    kit.cardBegin(id, .{ .icon = .keyboard, .title = which.title() });
    const recording = app.recording == which;
    const keys = app.store.shortcuts.get(which).get(which);
    const label = if (recording) "Press the keys…" else if (keys.len == 0) "None" else keys;
    if (kit.button(kit.print("sc/{t}/keys", .{which}), label, .{ .kind = if (recording) .accent else .standard })) {
        app.recording = if (recording) null else which;
    }
    _ = kit.cardEnd(false);
}

fn pactl(app: *Settings, argv: []const []const u8) void {
    const result = std.process.run(app.gpa, app.io, .{ .argv = argv }) catch |err| {
        log.warn("{s}: {t}", .{ argv[1], err });
        return;
    };
    app.gpa.free(result.stdout);
    app.gpa.free(result.stderr);
}

fn readSound(app: *Settings) void {
    const s = &app.system_state;
    const gpa = app.gpa;
    s.sound_known = false;
    const volume = std.process.run(gpa, app.io, .{ .argv = &.{ "pactl", "get-sink-volume", "@DEFAULT_SINK@" } }) catch return;
    defer gpa.free(volume.stdout);
    defer gpa.free(volume.stderr);
    // "Volume: front-left: 65536 / 100% / ...": the first percentage.
    const percent_at = std.mem.indexOfScalar(u8, volume.stdout, '%') orelse return;
    var start = percent_at;
    while (start > 0 and std.ascii.isDigit(volume.stdout[start - 1])) start -= 1;
    s.volume = @floatFromInt(std.fmt.parseInt(u32, volume.stdout[start..percent_at], 10) catch return);
    const mute = std.process.run(gpa, app.io, .{ .argv = &.{ "pactl", "get-sink-mute", "@DEFAULT_SINK@" } }) catch return;
    defer gpa.free(mute.stdout);
    defer gpa.free(mute.stderr);
    s.muted = std.mem.endsWith(u8, std.mem.trimEnd(u8, mute.stdout, " \n"), "yes");
    s.sound_known = true;
    readSinks(app);
    readInput(app);
}

/// The default microphone's volume and mute, and the microphones there are.
fn readInput(app: *Settings) void {
    const s = &app.system_state;
    const gpa = app.gpa;
    s.input_known = false;
    const volume = std.process.run(gpa, app.io, .{ .argv = &.{ "pactl", "get-source-volume", "@DEFAULT_SOURCE@" } }) catch return;
    defer gpa.free(volume.stdout);
    defer gpa.free(volume.stderr);
    const percent_at = std.mem.indexOfScalar(u8, volume.stdout, '%') orelse return;
    var start = percent_at;
    while (start > 0 and std.ascii.isDigit(volume.stdout[start - 1])) start -= 1;
    s.input_volume = @floatFromInt(std.fmt.parseInt(u32, volume.stdout[start..percent_at], 10) catch return);
    const mute = std.process.run(gpa, app.io, .{ .argv = &.{ "pactl", "get-source-mute", "@DEFAULT_SOURCE@" } }) catch return;
    defer gpa.free(mute.stdout);
    defer gpa.free(mute.stderr);
    s.input_muted = std.mem.endsWith(u8, std.mem.trimEnd(u8, mute.stdout, " \n"), "yes");
    s.input_known = true;

    s.source_count = 0;
    const list = std.process.run(gpa, app.io, .{ .argv = &.{ "pactl", "--format=json", "list", "sources" } }) catch return;
    defer gpa.free(list.stdout);
    defer gpa.free(list.stderr);
    const default = std.process.run(gpa, app.io, .{ .argv = &.{ "pactl", "get-default-source" } }) catch return;
    defer gpa.free(default.stdout);
    defer gpa.free(default.stderr);
    const default_name = std.mem.trim(u8, default.stdout, " \n");
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, list.stdout, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .array) return;
    for (parsed.value.array.items) |item| {
        if (s.source_count == s.sources.len) break;
        if (item != .object) continue;
        const name = item.object.get("name") orelse continue;
        const description = item.object.get("description") orelse name;
        if (name != .string or description != .string) continue;
        // An output's monitor is not something to speak into.
        if (std.mem.endsWith(u8, name.string, ".monitor")) continue;
        var source: Sink = .{};
        source.name.set(name.string);
        source.description.set(description.string);
        if (std.mem.eql(u8, name.string, default_name)) s.source_choice.selected = s.source_count;
        s.sources[s.source_count] = source;
        s.source_count += 1;
    }
}

fn readSinks(app: *Settings) void {
    const s = &app.system_state;
    const gpa = app.gpa;
    s.sink_count = 0;
    const list = std.process.run(gpa, app.io, .{ .argv = &.{ "pactl", "--format=json", "list", "sinks" } }) catch return;
    defer gpa.free(list.stdout);
    defer gpa.free(list.stderr);
    const default = std.process.run(gpa, app.io, .{ .argv = &.{ "pactl", "get-default-sink" } }) catch return;
    defer gpa.free(default.stdout);
    defer gpa.free(default.stderr);
    const default_name = std.mem.trim(u8, default.stdout, " \n");
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, list.stdout, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .array) return;
    for (parsed.value.array.items) |item| {
        if (s.sink_count == s.sinks.len) break;
        if (item != .object) continue;
        const name = item.object.get("name") orelse continue;
        const description = item.object.get("description") orelse name;
        if (name != .string or description != .string) continue;
        var sink: Sink = .{};
        sink.name.set(name.string);
        sink.description.set(description.string);
        if (std.mem.eql(u8, name.string, default_name)) s.sink_choice.selected = s.sink_count;
        s.sinks[s.sink_count] = sink;
        s.sink_count += 1;
    }
}

// -------------------------------------------------------------------------
// Notifications
// -------------------------------------------------------------------------

fn notifications(app: *Settings, kit: *Kit) void {
    kit.cardBegin("dnd", .{ .icon = .alert_snooze, .title = "Do not disturb", .description = "Notifications go straight to the notification center, without a toast" });
    if (kit.toggle("dnd/toggle", &app.store.do_not_disturb, .{})) app.save();
    _ = kit.cardEnd(false);
}

// -------------------------------------------------------------------------
// Power
// -------------------------------------------------------------------------

fn power(app: *Settings, kit: *Kit) void {
    const s = &app.system_state;
    kit.section("Screen");
    kit.cardBegin("screen-off", .{ .icon = .desktop, .title = "Turn off my screen after", .description = "The session locks as the screen goes dark" });
    if (kit.dropdown("screen-off/list", &s.screen_off, &screen_off_names, .fixed(180))) {
        app.store.screen_off_minutes = screen_off_minutes[s.screen_off.selected];
        app.save();
    }
    _ = kit.cardEnd(false);
    kit.section("Power");
    kit.cardBegin("power-mode", .{ .icon = .leaf_two, .title = "Power mode", .description = if (s.profile_service == null) "Power modes need power-profiles-daemon" else "Optimize your device based on power use and performance" });
    if (s.profile_service != null) {
        if (kit.dropdown("power-mode/list", &s.profile_choice, &profile_names, .fixed(220))) setProfile(app);
    }
    _ = kit.cardEnd(false);
}

const ProfileRead = struct { app: *Settings, service: usize };
var profile_read: ProfileRead = undefined;

fn readProfile(app: *Settings, service: usize) void {
    const bus = app.system orelse return;
    if (service >= profile_services.len) return;
    profile_read = .{ .app = app, .service = service };
    _ = bus.call(.{
        .destination = profile_services[service].name,
        .path = profile_services[service].path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .signature = "ss",
        .args = &.{ .{ .string = profile_services[service].name }, .{ .string = "ActiveProfile" } },
    }, .{ .context = &profile_read, .call = gotProfile }) catch {};
}

fn gotProfile(context: *anyopaque, _: *dbus.Connection, message: *const dbus.Message) void {
    const read: *ProfileRead = @ptrCast(@alignCast(context));
    const app = read.app;
    // The older name, where the newer is not.
    if (message.isError()) return readProfile(app, read.service + 1);
    const active = (message.arg(0) orelse return).asString() orelse return;
    const s = &app.system_state;
    s.profile_service = read.service;
    s.profile.set(active);
    for (profiles, 0..) |p, i| if (std.mem.eql(u8, p, active)) {
        s.profile_choice.selected = i;
    };
    app.window.redraw();
}

fn setProfile(app: *Settings) void {
    const s = &app.system_state;
    const bus = app.system orelse return;
    const service = profile_services[s.profile_service orelse return];
    const value: Value.Variant = .{ .signature = "s", .value = .{ .string = profiles[s.profile_choice.selected] } };
    _ = bus.call(.{
        .destination = service.name,
        .path = service.path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .signature = "ssv",
        .args = &.{ .{ .string = service.name }, .{ .string = "ActiveProfile" }, .{ .variant = &value } },
    }, null) catch {};
}

// -------------------------------------------------------------------------
// About
// -------------------------------------------------------------------------

fn about(app: *Settings, kit: *Kit) void {
    const s = &app.system_state;
    const u = kit.ui;
    const p = &kit.theme.palette;
    {
        u.open(.{ .width = .grow, .padding = .trbl(4, 4, 16, 4), .gap = 16, .align_y = .center });
        defer u.close();
        kit.icon(.laptop, 48, p.accent_text, .regular);
        u.open(.{ .direction = .top_to_bottom });
        defer u.close();
        kit.label(s.host.get(), .subtitle, p.text_primary);
        kit.label(s.os.get(), .body, p.text_secondary);
    }
    kit.section("Device specifications");
    Settings.infoCard(kit, "about/name", .laptop, "Device name", s.host.get());
    Settings.infoCard(kit, "about/cpu", .board, "Processor", s.cpu.get());
    Settings.infoCard(kit, "about/ram", .storage, "Installed RAM", kit.print("{d:.1} GB", .{s.ram_gb}));
    kit.section("System specifications");
    Settings.infoCard(kit, "about/os", .desktop, "Edition", s.os.get());
    Settings.infoCard(kit, "about/desktop", .window, "Desktop", "Fluxion Desktop 0.1");
    Settings.infoCard(kit, "about/kernel", .code, "Kernel", s.kernel.get());
}

fn readAbout(s: *State) void {
    if (s.about_read) return;
    s.about_read = true;
    var names: std.c.utsname = undefined;
    if (std.c.uname(&names) == 0) {
        s.host.set(std.mem.sliceTo(&names.nodename, 0));
        s.kernel.set(std.mem.sliceTo(&names.release, 0));
    }
    var buffer: [16384]u8 = undefined;
    if (readSmall("/proc/cpuinfo", &buffer)) |text| {
        if (field(text, "model name")) |model| s.cpu.set(model);
    }
    if (readSmall("/proc/meminfo", &buffer)) |text| {
        if (field(text, "MemTotal")) |total| {
            const kb = std.fmt.parseInt(u64, std.mem.trimEnd(u8, total, " kB"), 10) catch 0;
            s.ram_gb = @as(f32, @floatFromInt(kb)) / (1024 * 1024);
        }
    }
    if (readSmall("/etc/os-release", &buffer)) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| if (std.mem.startsWith(u8, line, "PRETTY_NAME=")) {
            s.os.set(std.mem.trim(u8, line["PRETTY_NAME=".len..], "\""));
        };
    }
}

/// A small file whole, read with plain calls: what /proc offers has no
/// size to ask for.
fn readSmall(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = std.c.open(path, .{});
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var len: usize = 0;
    while (len < buffer.len) {
        const n = std.c.read(fd, buffer[len..].ptr, buffer.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return buffer[0..len];
}

/// "name : value" in /proc's way: the value of the first line named so.
fn field(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name)) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

test "a /proc line is read by its name" {
    const text = "processor\t: 0\nmodel name\t: AMD Ryzen 7 5800X 8-Core Processor\nMemTotal:       32768000 kB\n";
    try std.testing.expectEqualStrings("AMD Ryzen 7 5800X 8-Core Processor", field(text, "model name").?);
    try std.testing.expectEqualStrings("32768000 kB", field(text, "MemTotal").?);
}
