// SPDX-License-Identifier: BSD-2-Clause

//! The window Settings is drawn in: an xdg-shell toplevel, its title bar
//! the compositor's where it draws one - Fluxion's, with its caption
//! buttons - and what is in it drawn with Fluxion UI's CPU renderer into
//! shared memory, as the desktop's own shell draws its panels.
//!
//! **Drawn only when something changed**, at most once a frame: `redraw`
//! marks it, and the drawing waits for the compositor's frame callback.
//! The pointer, the wheel and the keyboard are turned into what the `Ui`
//! takes; a key held repeats at the rate the compositor says.

const std = @import("std");
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;
const xkb = @import("xkbcommon");

const ui = @import("fluxion_ui");
const raster = @import("fluxion_ui_raster");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const ShmBuffer = @import("ShmBuffer.zig");
const Icons = @import("Icons.zig");

const Window = @This();

const log = std.log.scoped(.window);

/// Something else the loop waits on: a bus, a thread's pipe.
pub const Watch = struct {
    fd: std.c.fd_t,
    context: *anyopaque,
    ready: *const fn (context: *anyopaque) void,
    /// Whether it has something to write, waiting for room.
    wants_write: ?*const fn (context: *anyopaque) bool = null,
};

pub const Content = struct {
    context: *anyopaque,
    draw: *const fn (context: *anyopaque, window: *Window, kit: *Kit) void,
    /// A key the content wants before a text field does. True when it took it.
    key: ?*const fn (context: *anyopaque, window: *Window, sym: xkb.Keysym) bool = null,
};

gpa: std.mem.Allocator,
io: std.Io,
display: *wl.Display,
registry: *wl.Registry,
compositor: ?*wl.Compositor = null,
shm: ?*wl.Shm = null,
wm_base: ?*xdg.WmBase = null,
decorations: ?*zxdg.DecorationManagerV1 = null,
seat: ?*wl.Seat = null,
fractional_manager: ?*wp.FractionalScaleManagerV1 = null,
viewporter: ?*wp.Viewporter = null,
/// The screens, for Display: where the compositor tells of them.
output_manager: ?*zwlr.OutputManagerV1 = null,
pointer: ?*wl.Pointer = null,
keyboard: ?*wl.Keyboard = null,

surface: *wl.Surface = undefined,
xdg_surface: *xdg.Surface = undefined,
toplevel: *xdg.Toplevel = undefined,
decoration: ?*zxdg.ToplevelDecorationV1 = null,
/// How many of the screen's pixels each of the window's is - 1.5 at 150 %:
/// drawn that much bigger, every length in the drawing with it, and shown
/// at its size, so it is sharp at any scale. The content works in the
/// window's own pixels throughout: `width`, `boxOf`.
scale: f32 = 1,
fractional: ?*wp.FractionalScaleV1 = null,
viewport: ?*wp.Viewport = null,
shown_size: [2]u32 = .{ 0, 0 },

content: Content,
theme: widgets.Theme,
font_files: widgets.Fonts.Files,
fonts: widgets.Fonts = undefined,
painter: raster.Renderer = undefined,
icons: Icons = undefined,
layout: ui.Ui,

width: u32 = 1000,
height: u32 = 700,
configured: bool = false,
pending_size: ?[2]u32 = null,
running: bool = true,
dirty: bool = true,
rendering: bool = false,
frame_callback: ?*wl.Callback = null,
/// Drawn into in turn: one the compositor has just let go of is not drawn
/// into again at once.
buffers: [3]?*ShmBuffer = .{ null, null, null },
next_buffer: usize = 0,

pointer_at: ?[2]f32 = null,
down: bool = false,
pressed_since_drawn: bool = false,
input_since_drawn: bool = false,
axis_wheel: bool = true,
scroll_pending: f32 = 0,
last_frame_ms: i64 = 0,

xkb_context: ?*xkb.Context = null,
xkb_keymap: ?*xkb.Keymap = null,
xkb_state: ?*xkb.State = null,
/// A key held, repeating: which, and when it next types again.
repeat_key: ?u32 = null,
repeat_at_ms: i64 = 0,
repeat_delay_ms: i32 = 400,
repeat_rate_ms: i32 = 33,
watches: [4]Watch = undefined,
watch_count: usize = 0,
/// When to draw again with nothing else happening - a countdown's next
/// second - or nought.
wake_at_ms: i64 = 0,

const button_left = 0x110;

pub fn init(self: *Window, gpa: std.mem.Allocator, io: std.Io, title: [:0]const u8, app_id: [:0]const u8, mode: widgets.Mode, accent: widgets.theme.Accent, content: Content) !void {
    const display = try wl.Display.connect(null);
    errdefer display.disconnect();
    const font_files = try widgets.Fonts.readSystem(gpa, io) orelse {
        log.err("no interface font found; install Inter (dnf install rsms-inter-fonts)", .{});
        return error.NoFont;
    };
    self.* = .{
        .gpa = gpa,
        .io = io,
        .display = display,
        .registry = try display.getRegistry(),
        .content = content,
        .theme = .init(mode, accent),
        .font_files = font_files,
        .layout = .init(gpa),
    };
    self.fonts = try .init(font_files.text, font_files.strong);
    self.painter = try .init(gpa, &self.fonts.text);
    const faces = self.fonts.faces();
    try self.painter.setFaces(&faces);
    self.icons = .init(gpa, io, null);
    self.layout.setMeasurer(self.fonts.measurer());
    self.xkb_context = xkb.Context.new(.no_flags);

    self.registry.setListener(*Window, registryListener, self);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    const compositor = self.compositor orelse return error.MissingGlobals;
    const wm_base = self.wm_base orelse return error.MissingGlobals;
    if (self.shm == null) return error.MissingGlobals;

    self.surface = try compositor.createSurface();
    self.xdg_surface = try wm_base.getXdgSurface(self.surface);
    self.xdg_surface.setListener(*Window, xdgSurfaceListener, self);
    self.toplevel = try self.xdg_surface.getToplevel();
    self.toplevel.setListener(*Window, toplevelListener, self);
    self.toplevel.setTitle(title);
    self.toplevel.setAppId(app_id);
    self.toplevel.setMinSize(560, 420);
    if (self.fractional_manager) |manager| if (self.viewporter) |viewporter| {
        self.viewport = viewporter.getViewport(self.surface) catch null;
        if (self.viewport != null) {
            self.fractional = manager.getFractionalScale(self.surface) catch null;
            if (self.fractional) |f| f.setListener(*Window, fractionalListener, self);
        }
    };
    // The compositor's title bar, where it draws one.
    if (self.decorations) |manager| {
        self.decoration = manager.getToplevelDecoration(self.toplevel) catch null;
        if (self.decoration) |d| d.setMode(.server_side);
    }
    self.surface.commit();
}

pub fn deinit(self: *Window) void {
    if (self.frame_callback) |c| c.destroy();
    for (self.buffers) |maybe| if (maybe) |b| b.destroy(self.gpa);
    if (self.decoration) |d| d.destroy();
    if (self.fractional) |f| f.destroy();
    if (self.viewport) |v| v.destroy();
    self.toplevel.destroy();
    self.xdg_surface.destroy();
    self.surface.destroy();
    self.layout.deinit();
    self.icons.deinit();
    self.painter.deinit();
    self.font_files.deinit(self.gpa);
    if (self.xkb_state) |s| s.unref();
    if (self.xkb_keymap) |k| k.unref();
    if (self.xkb_context) |c| c.unref();
    self.display.disconnect();
}

/// Change the look: light or dark, and the accent.
pub fn setTheme(self: *Window, mode: widgets.Mode, accent: widgets.theme.Accent) void {
    self.theme = .init(mode, accent);
    self.redraw();
}

/// Wait on `watch` too, and call it when it is ready.
pub fn addWatch(self: *Window, watch: Watch) void {
    if (self.watch_count == self.watches.len) return;
    self.watches[self.watch_count] = watch;
    self.watch_count += 1;
}

/// Run until the window is closed.
pub fn run(self: *Window) !void {
    while (self.running) {
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }
        _ = self.display.flush();
        var timeout: i32 = if (self.layout.wantsKeyboard()) 500 else -1;
        if (self.repeat_key != null) timeout = @intCast(std.math.clamp(self.repeat_at_ms - nowMs(), 0, 1000));
        if (self.wake_at_ms != 0) {
            const until: i32 = @intCast(std.math.clamp(self.wake_at_ms - nowMs(), 0, 1000));
            timeout = if (timeout < 0) until else @min(timeout, until);
        }
        var fds: [5]posix.pollfd = undefined;
        fds[0] = .{ .fd = self.display.getFd(), .events = posix.POLL.IN, .revents = 0 };
        for (self.watches[0..self.watch_count], 1..) |w, i| {
            const write = if (w.wants_write) |f| f(w.context) else false;
            fds[i] = .{ .fd = w.fd, .events = if (write) posix.POLL.IN | posix.POLL.OUT else posix.POLL.IN, .revents = 0 };
        }
        _ = posix.poll(fds[0 .. 1 + self.watch_count], timeout) catch 0;
        for (self.watches[0..self.watch_count], 1..) |w, i| {
            if (fds[i].revents != 0) w.ready(w.context);
        }
        if (fds[0].revents != 0) {
            if (self.display.readEvents() != .SUCCESS) return error.ConnectionLost;
        } else {
            self.display.cancelRead();
            // The caret blinks; a key held types again.
            if (self.repeat_key) |code| if (nowMs() >= self.repeat_at_ms) {
                self.repeat_at_ms = nowMs() + self.repeat_rate_ms;
                self.typeKey(code);
            };
            if (self.layout.wantsKeyboard()) self.redraw();
            if (self.wake_at_ms != 0 and nowMs() >= self.wake_at_ms) {
                self.wake_at_ms = 0;
                self.redraw();
            }
        }
        if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
    }
}

/// Draw again at `ms`, though nothing else happens by then.
pub fn wakeAt(self: *Window, ms: i64) void {
    if (self.wake_at_ms == 0 or ms < self.wake_at_ms) self.wake_at_ms = ms;
}

/// Something changed: draw again at the next chance.
pub fn redraw(self: *Window) void {
    self.dirty = true;
    if (self.rendering) return;
    if (self.configured and self.frame_callback == null) self.render();
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *Window) void {
    switch (event) {
        .global => |global| {
            const name = std.mem.span(global.interface);
            if (std.mem.eql(u8, name, std.mem.span(wl.Compositor.interface.name))) {
                self.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
                self.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(xdg.WmBase.interface.name))) {
                self.wm_base = registry.bind(global.name, xdg.WmBase, 3) catch return;
                self.wm_base.?.setListener(*Window, wmBaseListener, self);
            } else if (std.mem.eql(u8, name, std.mem.span(zxdg.DecorationManagerV1.interface.name))) {
                self.decorations = registry.bind(global.name, zxdg.DecorationManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wp.FractionalScaleManagerV1.interface.name))) {
                self.fractional_manager = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(zwlr.OutputManagerV1.interface.name))) {
                self.output_manager = registry.bind(global.name, zwlr.OutputManagerV1, @min(global.version, 4)) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wp.Viewporter.interface.name))) {
                self.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                if (self.seat != null) return;
                self.seat = registry.bind(global.name, wl.Seat, 7) catch return;
                self.seat.?.setListener(*Window, seatListener, self);
            }
        },
        .global_remove => {},
    }
}

fn fractionalListener(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, self: *Window) void {
    switch (event) {
        .preferred_scale => |e| {
            // In 120ths: 180 is 150 %.
            const scale = @as(f32, @floatFromInt(e.scale)) / 120;
            if (scale == self.scale) return;
            self.scale = scale;
            self.icons.scale = scale;
            self.redraw();
        },
    }
}

/// Its size in the screen's pixels: what it is drawn at.
fn pixelSize(self: *const Window) [2]u32 {
    return .{
        @intFromFloat(@round(@as(f32, @floatFromInt(self.width)) * self.scale)),
        @intFromFloat(@round(@as(f32, @floatFromInt(self.height)) * self.scale)),
    };
}

/// Where the element `id` is, in the window's pixels, as the last drawing
/// put it.
pub fn boxOf(self: *Window, id: []const u8) ?ui.BoundingBox {
    const b = self.layout.boxOf(id) orelse return null;
    const s = self.scale;
    return .{ .x = b.x / s, .y = b.y / s, .width = b.width / s, .height = b.height / s };
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Window) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *Window) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            if (self.pending_size) |size| {
                self.width = size[0];
                self.height = size[1];
                self.pending_size = null;
            }
            self.configured = true;
            self.dirty = true;
            if (self.frame_callback == null) self.render();
        },
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Window) void {
    switch (event) {
        .configure => |configure| {
            // Nought: the window picks its own size.
            if (configure.width > 0 and configure.height > 0) {
                self.pending_size = .{ @intCast(configure.width), @intCast(configure.height) };
            }
        },
        .close => self.running = false,
    }
}

// -------------------------------------------------------------------------
// Drawing
// -------------------------------------------------------------------------

fn freeBuffer(self: *Window) ?*ShmBuffer {
    const shm = self.shm orelse return null;
    const pw, const ph = self.pixelSize();
    for (0..self.buffers.len) |i| {
        const index = (self.next_buffer + i) % self.buffers.len;
        const slot = &self.buffers[index];
        self.next_buffer = (index + 1) % self.buffers.len;
        if (slot.*) |buffer| {
            if (buffer.busy) continue;
            if (buffer.width == pw and buffer.height == ph) return buffer;
            buffer.destroy(self.gpa);
            slot.* = null;
        }
        slot.* = ShmBuffer.create(self.gpa, shm, pw, ph) catch |err| {
            log.err("could not allocate a buffer: {t}", .{err});
            return null;
        };
        return slot.*.?;
    }
    return null;
}

fn render(self: *Window) void {
    if (self.width == 0 or self.height == 0) return;
    const buffer = self.freeBuffer() orelse return;
    self.dirty = false;
    self.rendering = true;
    defer self.rendering = false;
    self.scrollStep();

    const now = nowMs();
    if (self.last_frame_ms != 0) self.layout.tick(@as(f32, @floatFromInt(now - self.last_frame_ms)) / 1000);
    self.last_frame_ms = now;

    var kit: Kit = .init(&self.layout, &self.theme);
    var commands: []const ui.RenderCommand = &.{};
    const s = self.scale;
    // Twice: hover and press are answered from the drawing before.
    for (0..2) |pass| {
        const down = self.down or (pass == 0 and self.pressed_since_drawn);
        if (self.pointer_at) |p| {
            self.layout.setPointer(p[0] * s, p[1] * s, down);
        } else {
            self.layout.setPointer(-1000, -1000, false);
        }
        self.layout.begin(.{ .size = .init(@floatFromInt(buffer.width), @floatFromInt(buffer.height)), .scale = s });
        kit.frame();
        self.content.draw(self.content.context, self, &kit);
        commands = self.layout.end() catch |err| {
            log.err("could not lay out: {t}", .{err});
            return;
        };
    }
    self.pressed_since_drawn = false;
    const again = self.input_since_drawn;
    self.input_since_drawn = false;

    self.painter.setImages(self.icons.images.items);
    self.painter.draw(.init(buffer.pixels, buffer.width, buffer.height), commands, self.theme.palette.solid_base) catch |err| {
        log.err("could not draw: {t}", .{err});
    };
    self.surface.attach(buffer.wl_buffer, 0, 0);
    if (self.viewport) |viewport| if (self.shown_size[0] != self.width or self.shown_size[1] != self.height) {
        viewport.setDestination(@intCast(self.width), @intCast(self.height));
        self.shown_size = .{ self.width, self.height };
    };
    self.surface.damageBuffer(0, 0, @intCast(buffer.width), @intCast(buffer.height));
    if (self.surface.frame()) |callback| {
        callback.setListener(*Window, frameListener, self);
        self.frame_callback = callback;
    } else |_| {}
    buffer.busy = true;
    self.surface.commit();
    if (again) self.dirty = true;
}

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, self: *Window) void {
    switch (event) {
        .done => {
            callback.destroy();
            self.frame_callback = null;
            if (self.dirty) self.render();
        },
    }
}

/// A notch of the wheel goes three lines, smoothly over a few frames.
fn scrollStep(self: *Window) void {
    if (self.scroll_pending == 0) return;
    var step = self.scroll_pending * 0.35;
    if (@abs(self.scroll_pending) < 2) step = self.scroll_pending;
    if (!self.layout.scrollHovered(0, step * self.scale)) {
        self.scroll_pending = 0;
        return;
    }
    self.scroll_pending -= step;
    if (self.scroll_pending != 0) self.dirty = true;
}

// -------------------------------------------------------------------------
// Input
// -------------------------------------------------------------------------

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, self: *Window) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.pointer and self.pointer == null) {
                self.pointer = seat.getPointer() catch null;
                if (self.pointer) |p| p.setListener(*Window, pointerListener, self);
            }
            if (caps.capabilities.keyboard and self.keyboard == null) {
                self.keyboard = seat.getKeyboard() catch null;
                if (self.keyboard) |k| k.setListener(*Window, keyboardListener, self);
            }
        },
        .name => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, self: *Window) void {
    switch (event) {
        .enter => |enter| {
            self.pointer_at = .{ @floatCast(enter.surface_x.toDouble()), @floatCast(enter.surface_y.toDouble()) };
            self.redraw();
        },
        .leave => {
            self.pointer_at = null;
            self.down = false;
            self.redraw();
        },
        .motion => |motion| {
            self.pointer_at = .{ @floatCast(motion.surface_x.toDouble()), @floatCast(motion.surface_y.toDouble()) };
            self.redraw();
        },
        .button => |button| {
            if (button.button != button_left) return;
            self.down = button.state == .pressed;
            if (self.down) self.pressed_since_drawn = true;
            self.input_since_drawn = true;
            self.redraw();
        },
        .axis_source => |source| self.axis_wheel = source.axis_source == .wheel or source.axis_source == .wheel_tilt,
        .axis => |axis| {
            if (axis.axis != .vertical_scroll) return;
            const dy: f32 = @floatCast(axis.value.toDouble());
            if (self.axis_wheel) {
                self.scroll_pending += dy * 3;
            } else {
                _ = self.layout.scrollHovered(0, dy * self.scale);
            }
            self.redraw();
        },
        else => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Window) void {
    switch (event) {
        .keymap => |keymap| {
            defer _ = std.c.close(keymap.fd);
            if (keymap.format != .xkb_v1) return;
            const context = self.xkb_context orelse return;
            const memory = posix.mmap(null, keymap.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, keymap.fd, 0) catch return;
            defer posix.munmap(memory);
            const fresh = xkb.Keymap.newFromString(context, @ptrCast(memory.ptr), .text_v1, .no_flags) orelse return;
            if (self.xkb_keymap) |old| old.unref();
            if (self.xkb_state) |old| old.unref();
            self.xkb_keymap = fresh;
            self.xkb_state = xkb.State.new(fresh);
        },
        .enter => {},
        .leave => self.repeat_key = null,
        .modifiers => |m| {
            if (self.xkb_state) |state| _ = state.updateMask(m.mods_depressed, m.mods_latched, m.mods_locked, 0, 0, m.group);
        },
        .key => |key| {
            const code = key.key + 8;
            if (key.state != .pressed) {
                if (self.repeat_key == code) self.repeat_key = null;
                return;
            }
            self.typeKey(code);
            // Held, it types again: after a moment, then quickly.
            const keymap = self.xkb_keymap orelse return;
            if (keymap.keyRepeats(code) != 0) {
                self.repeat_key = code;
                self.repeat_at_ms = nowMs() + self.repeat_delay_ms;
            }
        },
        .repeat_info => |info| {
            if (info.rate > 0) self.repeat_rate_ms = @divTrunc(1000, info.rate);
            self.repeat_delay_ms = info.delay;
        },
    }
}

/// Whether the modifier `name` - xkb's "Control", "Shift", "Mod1" for
/// Alt, "Mod4" for Super - is held.
pub fn modifierHeld(self: *const Window, name: [*:0]const u8) bool {
    const state = self.xkb_state orelse return false;
    return state.modNameIsActive(name, @enumFromInt(xkb.State.Component.mods_effective)) == 1;
}

/// A key, as the keyboard typed it: the content's first, then the text
/// field's - an edit by where the key is, or the text it types.
fn typeKey(self: *Window, code: u32) void {
    const state = self.xkb_state orelse return;
    const sym = state.keyGetOneSym(code);
    self.input_since_drawn = true;
    if (self.content.key) |hook| if (hook(self.content.context, self, sym)) {
        self.redraw();
        return;
    };
    const effective: xkb.State.Component = @enumFromInt(xkb.State.Component.mods_effective);
    const ctrl = state.modNameIsActive(xkb.names.mod.ctrl, effective) == 1;
    const shift = state.modNameIsActive(xkb.names.mod.shift, effective) == 1;
    const Keysym = xkb.Keysym;
    const edit: ?ui.text_input.Action = switch (@intFromEnum(sym)) {
        Keysym.BackSpace => if (ctrl) .backspace_word else .backspace,
        Keysym.Delete => if (ctrl) .delete_word else .delete,
        Keysym.Left => .moveTo(if (ctrl) .word_left else .left, shift),
        Keysym.Right => .moveTo(if (ctrl) .word_right else .right, shift),
        Keysym.Home => .moveTo(.start, shift),
        Keysym.End => .moveTo(.end, shift),
        Keysym.Return, Keysym.KP_Enter => .submit,
        Keysym.a, Keysym.A => if (ctrl) .select_all else null,
        else => null,
    };
    if (edit) |action| {
        _ = self.layout.textAction(action);
    } else if (!ctrl) {
        var buffer: [16]u8 = undefined;
        const n = state.keyGetUtf8(code, &buffer);
        if (n > 0 and buffer[0] >= 0x20 and buffer[0] != 0x7F) self.layout.typeText(buffer[0..n]);
    }
    self.redraw();
}

pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
