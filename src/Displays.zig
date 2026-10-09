// SPDX-License-Identifier: BSD-2-Clause

//! The screens, as the compositor tells of them over wlr-output-management:
//! each one's name and maker, how big it is, the modes it takes and the one
//! it is in, how big everything on it is drawn - its scale - and which way
//! round it is. And asking for one of those to change: the compositor tries
//! it, and says whether it took.
//!
//! What it says arrives a piece at a time - a head, its modes, its state -
//! and holds together at `done`; Display is drawn again then.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Displays = @This();

const log = std.log.scoped(.displays);

pub const Mode = struct {
    object: *zwlr.OutputModeV1,
    width: i32 = 0,
    height: i32 = 0,
    /// In thousandths of a hertz.
    refresh: i32 = 0,
    preferred: bool = false,
    gone: bool = false,

    pub fn hz(self: *const Mode) f32 {
        return @as(f32, @floatFromInt(self.refresh)) / 1000;
    }
};

pub const Head = struct {
    owner: *Displays,
    object: *zwlr.OutputHeadV1,
    name: Text = .{},
    description: Text = .{},
    make: Text = .{},
    model: Text = .{},
    /// In millimetres; nought where the screen does not say.
    physical: [2]i32 = .{ 0, 0 },
    modes: std.ArrayList(*Mode) = .empty,
    enabled: bool = false,
    current: ?*Mode = null,
    position: [2]i32 = .{ 0, 0 },
    transform: wl.Output.Transform = .normal,
    scale: f64 = 1,
    gone: bool = false,

    /// "LG Electronics LG TV" - or its connector, where it says nothing of
    /// itself.
    pub fn title(self: *const Head, buffer: []u8) []const u8 {
        if (self.make.len > 0 and self.model.len > 0) {
            return std.fmt.bufPrint(buffer, "{s} {s}", .{ self.make.get(), self.model.get() }) catch self.name.get();
        }
        if (self.description.len > 0) return self.description.get();
        return self.name.get();
    }

    /// The mode it prefers: its own size, at its best rate.
    pub fn preferredMode(self: *const Head) ?*Mode {
        for (self.modes.items) |m| if (m.preferred and !m.gone) return m;
        return if (self.modes.items.len > 0) self.modes.items[0] else null;
    }

    /// Its size on the screen, after the turn: what the layout sees, before
    /// the scale.
    pub fn turnedSize(self: *const Head) [2]i32 {
        const m = self.current orelse return .{ 0, 0 };
        return switch (self.transform) {
            .@"90", .@"270", .flipped_90, .flipped_270 => .{ m.height, m.width },
            else => .{ m.width, m.height },
        };
    }

    /// The scale Windows would recommend for it: from how many pixels it
    /// has to the inch, and how far away it is looked at - a laptop's own
    /// screen from closer than a desk's, a television's from across the
    /// room.
    pub fn recommendedScale(self: *const Head) f64 {
        const mode = self.preferredMode() orelse return 1;
        const name = self.name.get();
        const built_in = std.mem.startsWith(u8, name, "eDP") or std.mem.startsWith(u8, name, "LVDS") or std.mem.startsWith(u8, name, "DSI");
        return @min(recommended(mode.width, mode.height, self.physical[0], self.physical[1], built_in), self.largestScale());
    }

    /// The largest scale that leaves room to work in - about 1024 by 600
    /// of the layout's pixels - as Windows offers no more than 175 % at
    /// 1080p.
    pub fn largestScale(self: *const Head) f64 {
        const m = self.current orelse return 1;
        const w: f64 = @floatFromInt(@max(m.width, m.height));
        const h: f64 = @floatFromInt(@min(m.width, m.height));
        return @max(1, @floor(@min(w / 1024, h / 600) * 4) / 4);
    }
};

pub const Text = struct {
    buffer: [128]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Text, text: []const u8) void {
        self.len = @min(text.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], text[0..self.len]);
    }

    pub fn get(self: *const Text) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub const Change = struct {
    mode: ?*Mode = null,
    scale: ?f64 = null,
    transform: ?wl.Output.Transform = null,
};

pub const Outcome = enum { none, waiting, succeeded, failed };

gpa: std.mem.Allocator,
manager: *zwlr.OutputManagerV1,
heads: std.ArrayList(*Head) = .empty,
serial: u32 = 0,
/// Whether the compositor has said all it has to say at least once.
known: bool = false,
/// The last change asked for, and what became of it.
outcome: Outcome = .none,
asking: ?*zwlr.OutputConfigurationV1 = null,
/// Called once what is known changed: the page drawn again.
changed: ?struct { context: *anyopaque, call: *const fn (context: *anyopaque) void } = null,

pub fn init(gpa: std.mem.Allocator, manager: *zwlr.OutputManagerV1) !*Displays {
    const self = try gpa.create(Displays);
    self.* = .{ .gpa = gpa, .manager = manager };
    manager.setListener(*Displays, managerListener, self);
    return self;
}

pub fn deinit(self: *Displays) void {
    for (self.heads.items) |head| self.freeHead(head);
    self.heads.deinit(self.gpa);
    if (self.asking) |c| c.destroy();
    self.manager.stop();
    self.gpa.destroy(self);
}

fn freeHead(self: *Displays, head: *Head) void {
    for (head.modes.items) |m| {
        m.object.destroy();
        self.gpa.destroy(m);
    }
    head.modes.deinit(self.gpa);
    head.object.destroy();
    self.gpa.destroy(head);
}

/// The screens still there.
pub fn list(self: *const Displays) []const *Head {
    return self.heads.items;
}

/// Ask for `head` to change as `change` says, the others as they are.
/// What the compositor makes of it comes in `outcome`.
pub fn apply(self: *Displays, head: *Head, change: Change) void {
    if (self.asking) |old| old.destroy();
    const config = self.manager.createConfiguration(self.serial) catch return;
    config.setListener(*Displays, configurationListener, self);
    for (self.heads.items) |h| {
        if (!h.enabled) {
            config.disableHead(h.object);
            continue;
        }
        const ch = config.enableHead(h.object) catch continue;
        if (h != head) continue;
        if (change.mode) |m| ch.setMode(m.object);
        if (change.scale) |s| ch.setScale(.fromDouble(s));
        if (change.transform) |t| ch.setTransform(t);
    }
    config.apply();
    self.asking = config;
    self.outcome = .waiting;
}

fn configurationListener(config: *zwlr.OutputConfigurationV1, event: zwlr.OutputConfigurationV1.Event, self: *Displays) void {
    self.outcome = switch (event) {
        .succeeded => .succeeded,
        .failed => .failed,
        // Something changed meanwhile: asked against what is no more.
        .cancelled => .failed,
    };
    if (self.outcome == .failed) log.warn("the compositor did not take the change", .{});
    config.destroy();
    if (self.asking == config) self.asking = null;
    self.tell();
}

fn tell(self: *Displays) void {
    if (self.changed) |c| c.call(c.context);
}

fn managerListener(_: *zwlr.OutputManagerV1, event: zwlr.OutputManagerV1.Event, self: *Displays) void {
    switch (event) {
        .head => |e| {
            const head = self.gpa.create(Head) catch return;
            head.* = .{ .owner = self, .object = e.head };
            e.head.setListener(*Head, headListener, head);
            self.heads.append(self.gpa, head) catch {
                self.gpa.destroy(head);
                return;
            };
        },
        .done => |e| {
            self.serial = e.serial;
            self.known = true;
            // What went is let go of now that it is all said.
            var i: usize = 0;
            while (i < self.heads.items.len) {
                const head = self.heads.items[i];
                if (head.gone) {
                    _ = self.heads.orderedRemove(i);
                    self.freeHead(head);
                    continue;
                }
                var j: usize = 0;
                while (j < head.modes.items.len) {
                    const m = head.modes.items[j];
                    if (m.gone) {
                        if (head.current == m) head.current = null;
                        _ = head.modes.orderedRemove(j);
                        m.object.destroy();
                        self.gpa.destroy(m);
                        continue;
                    }
                    j += 1;
                }
                i += 1;
            }
            self.tell();
        },
        .finished => {},
    }
}

fn headListener(_: *zwlr.OutputHeadV1, event: zwlr.OutputHeadV1.Event, head: *Head) void {
    const gpa = head.owner.gpa;
    switch (event) {
        .name => |e| head.name.set(std.mem.span(e.name)),
        .description => |e| head.description.set(std.mem.span(e.description)),
        .make => |e| head.make.set(std.mem.span(e.make)),
        .model => |e| head.model.set(std.mem.span(e.model)),
        .serial_number => {},
        .physical_size => |e| head.physical = .{ e.width, e.height },
        .mode => |e| {
            const m = gpa.create(Mode) catch return;
            m.* = .{ .object = e.mode };
            e.mode.setListener(*Mode, modeListener, m);
            head.modes.append(gpa, m) catch gpa.destroy(m);
        },
        .enabled => |e| head.enabled = e.enabled != 0,
        .current_mode => |e| {
            head.current = null;
            for (head.modes.items) |m| if (m.object == e.mode) {
                head.current = m;
            };
        },
        .position => |e| head.position = .{ e.x, e.y },
        .transform => |e| head.transform = e.transform,
        .scale => |e| head.scale = e.scale.toDouble(),
        .adaptive_sync => {},
        .finished => head.gone = true,
    }
}

fn modeListener(_: *zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event, m: *Mode) void {
    switch (event) {
        .size => |e| {
            m.width = e.width;
            m.height = e.height;
        },
        .refresh => |e| m.refresh = e.refresh,
        .preferred => m.preferred = true,
        .finished => m.gone = true,
    }
}

/// The scale for a screen `width` by `height` pixels and `mm_w` by `mm_h`
/// millimetres, as Windows works it out: its pixels to the inch, times how
/// far away a screen of its kind is looked at, against 96 at 28 inches -
/// a desk's screen - to the nearest quarter, a little below rather than
/// above.
pub fn recommended(width: i32, height: i32, mm_w: i32, mm_h: i32, built_in: bool) f64 {
    _ = height;
    // Saying nothing of its size: as it is.
    if (mm_w <= 0 or mm_h <= 0) return 1;
    const mw: f64 = @floatFromInt(mm_w);
    const mh: f64 = @floatFromInt(mm_h);
    const inches = @sqrt(mw * mw + mh * mh) / 25.4;
    const dpi = @as(f64, @floatFromInt(width)) / (mw / 25.4);
    const distance: f64 = if (built_in) (if (inches <= 11) 20 else 24.5) else if (inches >= 40) 84 else 28;
    const scale = @round(dpi * distance / (96 * 28) * 4 - 0.1) / 4;
    return std.math.clamp(scale, 1, 5);
}

test "the scales Windows recommends for the usual screens" {
    // Microsoft's own table: a 15.4-inch laptop at 1080p, 125 %; 13.3-inch
    // at 1440p, 200 %; a 24-inch screen at 1440p, 125 %; 23-inch at 4K,
    // 200 %.
    try std.testing.expectEqual(@as(f64, 1.25), recommended(1920, 1080, 341, 192, true));
    try std.testing.expectEqual(@as(f64, 2), recommended(2560, 1440, 294, 166, true));
    try std.testing.expectEqual(@as(f64, 1.25), recommended(2560, 1440, 531, 299, false));
    try std.testing.expectEqual(@as(f64, 2), recommended(3840, 2160, 509, 286, false));
    // A 27-inch screen at 1440p: 100 %.
    try std.testing.expectEqual(@as(f64, 1), recommended(2560, 1440, 597, 336, false));
    // A 55-inch television at 4K, looked at from the sofa: 250 %.
    try std.testing.expectEqual(@as(f64, 2.5), recommended(3840, 2160, 1210, 680, false));
}
